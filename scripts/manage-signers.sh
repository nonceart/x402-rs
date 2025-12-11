#!/usr/bin/env zsh
#
# manage-signers.sh - Manage EVM signer keys for x402 facilitators on Fly.io
#
# USAGE:
#   ./manage-signers.sh scale   <fly.toml> <target-count> [--extra-wallet <key>]...
#   ./manage-signers.sh rebalance <fly.toml> [--extra-wallet <key>]...
#
# MODES:
#   scale     - Add new keys to reach target count, redistribute ETH, update Fly secrets, restart
#   rebalance - Only redistribute ETH among existing keys (no new keys, no restart)
#
# OPTIONS:
#   --extra-wallet <key>  Additional private key(s) to use as funding source (will be drained)
#   --rpc-url <url>       custom RPC endpoint
#   --dry-run             Show what would happen without making changes
#   --yes                 Skip backup confirmation prompt (dangerous!)
#
# EXAMPLES:
#   # Scale x402-preconf to 20 signers
#   ./manage-signers.sh scale ../fly.x402-preconf.toml 20
#
#   # Scale with extra funding wallet
#   ./manage-signers.sh scale ../fly.x402.toml 10 --extra-wallet 0xabc...
#
#   # Rebalance existing keys (no changes to key count)
#   ./manage-signers.sh rebalance ../fly.x402-pub.toml
#
#   # Rebalance with additional funding source
#   ./manage-signers.sh rebalance ../fly.x402.toml --extra-wallet 0xabc...
#
# REQUIREMENTS:
#   - cast (foundry) - for key generation and transfers
#   - fly CLI - for secrets and SSH
#
# DEFAULT TARGETS (if not specified in scale mode):
#   x402:         10 signers
#   x402-cdp:     10 signers
#   x402-preconf: 20 signers
#   x402-pub:     10 signers
#

set -euo pipefail
set +xv  # Disable xtrace and verbose if inherited from parent shell

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Defaults
RPC_URL="${RPC_URL:-https://rpc.com}"
DRY_RUN=false
SKIP_CONFIRMATION=false
EXTRA_WALLETS=()

# Default target counts per facilitator (zsh associative array)
typeset -A DEFAULT_TARGETS
DEFAULT_TARGETS=(
    nonceart-x402 10
    nonceart-x402-cdp 10
    nonceart-x402-preconf 20
    nonceart-x402-pub 10
)

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# Print a key for backup (formatted nicely)
print_key_for_backup() {
    local index=$1
    local address=$2
    local private_key=$3
    echo -e "${CYAN}[$index]${NC} Address: $address"
    echo "    Private Key: $private_key"
}

# Check required tools
check_dependencies() {
    local missing=()
    command -v cast >/dev/null 2>&1 || missing+=("cast (foundry)")
    command -v fly >/dev/null 2>&1 || missing+=("fly")

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required tools: ${missing[*]}"
        echo "Install instructions:"
        echo "  cast: curl -L https://foundry.paradigm.xyz | bash && foundryup"
        echo "  fly:  brew install flyctl"
        exit 1
    fi
}

# Parse fly.toml to get app name
get_app_name() {
    local fly_toml=$1
    grep '^app = ' "$fly_toml" | sed 's/app = "\(.*\)"/\1/'
}

# Fetch existing keys from Fly.io via SSH
fetch_existing_keys() {
    local app_name=$1
    log_info "Fetching existing keys from $app_name via SSH..." >&2

    local raw_keys
    raw_keys=$(fly ssh console -a "$app_name" -C "printenv EVM_PRIVATE_KEY" --quiet 2>/dev/null || echo "")

    if [[ -z "$raw_keys" ]]; then
        log_warn "No existing EVM_PRIVATE_KEY found or SSH failed" >&2
        echo ""
        return
    fi

    # Trim all whitespace (newlines, spaces, etc.)
    raw_keys="${raw_keys//[$'\n\r\t ']/}"
    echo "$raw_keys"
}

# Parse comma-separated keys into array
parse_keys_to_array() {
    local raw_keys=$1
    local -a result=()

    # Split by comma
    local IFS=','
    for key in ${(s:,:)raw_keys}; do
        # Trim whitespace
        key="${key//[[:space:]]/}"
        if [[ -n "$key" ]]; then
            result+=("$key")
        fi
    done

    # Return array elements, one per line
    printf '%s\n' "${result[@]}"
}

# Normalize private key to have 0x prefix (for cast commands)
normalize_key() {
    local key=$1
    if [[ "$key" = 0x* ]]; then
        echo "$key"
    else
        echo "0x$key"
    fi
}

# Strip 0x prefix from key (for storage consistency)
strip_0x() {
    local key=$1
    echo "${key#0x}"
}

# Get address from private key
key_to_address() {
    local private_key=$(normalize_key "$1")
    cast wallet address "$private_key" 2>/dev/null
}

# Get balance of an address in wei
get_balance_wei() {
    local address=$1
    cast balance "$address" --rpc-url "$RPC_URL" 2>/dev/null || echo "0"
}

# Get balance formatted in ETH
get_balance_eth() {
    local address=$1
    cast balance "$address" --rpc-url "$RPC_URL" --ether 2>/dev/null || echo "0"
}

# Generate a new wallet
generate_wallet() {
    local output
    output=$(cast wallet new 2>/dev/null)

    local address private_key
    address=$(echo "$output" | grep "Address:" | awk '{print $2}')
    private_key=$(echo "$output" | grep "Private key:" | awk '{print $3}')

    echo "$address $private_key"
}

# Send ETH from one account to another (waits for confirmation)
send_eth() {
    local from_key=$(normalize_key "$1")
    local to_address=$2
    local amount_wei=$3
    local amount_eth
    amount_eth=$(cast from-wei "$amount_wei" ether 2>/dev/null || echo "?")

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would send $amount_eth ETH to $to_address"
        return 0
    fi

    # Retry logic for nonce issues (RPC state propagation delay)
    local max_retries=3
    local retry=0
    local output

    while [[ $retry -lt $max_retries ]]; do
        if output=$(cast send "$to_address" \
            --value "${amount_wei}" \
            --private-key "$from_key" \
            --rpc-url "$RPC_URL" \
            --confirmations 1 \
            --json 2>&1); then

            # Extract tx hash from JSON output
            local tx_hash
            tx_hash=$(echo "$output" | grep -o '"transactionHash":"0x[a-fA-F0-9]*"' | cut -d'"' -f4 || echo "")
            if [[ -n "$tx_hash" ]]; then
                log_success "Sent $amount_eth ETH (tx: ${tx_hash:0:18}...)"
            else
                log_success "Sent $amount_eth ETH (confirmed)"
            fi

            # Small delay to let RPC state propagate before next tx from same sender
            sleep 1
            return 0
        fi

        # Check if it's a nonce error - worth retrying
        if [[ "$output" == *"nonce too low"* ]] || [[ "$output" == *"nonce"* ]]; then
            retry=$((retry + 1))
            if [[ $retry -lt $max_retries ]]; then
                log_warn "Nonce issue, retrying in 2s... (attempt $((retry + 1))/$max_retries)"
                sleep 2
            fi
        else
            # Non-nonce error, don't retry
            break
        fi
    done

    log_error "Transaction failed: $output"
    return 1
}

# Calculate gas cost for a transfer (estimate)
estimate_gas_cost() {
    # Simple ETH transfer is 21000 gas
    local gas_price
    gas_price=$(cast gas-price --rpc-url "$RPC_URL" 2>/dev/null || echo "1000000000")
    echo $((21000 * gas_price))
}

# Main scale function
do_scale() {
    local fly_toml=$1
    local target_count=$2

    if [[ ! -f "$fly_toml" ]]; then
        log_error "fly.toml not found: $fly_toml"
        exit 1
    fi

    local app_name
    app_name=$(get_app_name "$fly_toml")
    log_info "App: $app_name"

    # Use default target if not specified
    if [[ -z "$target_count" ]] || [[ "$target_count" == "0" ]]; then
        target_count=${DEFAULT_TARGETS[$app_name]:-10}
        log_info "Using default target count: $target_count"
    fi

    # Fetch existing keys
    local raw_keys
    raw_keys=$(fetch_existing_keys "$app_name")

    local -a existing_keys=()
    if [[ -n "$raw_keys" ]]; then
        while IFS= read -r key; do
            [[ -n "$key" ]] && existing_keys+=("$key")
        done < <(parse_keys_to_array "$raw_keys")
    fi

    local current_count=${#existing_keys[@]}
    log_info "Current signers: $current_count, Target: $target_count"

    if [[ $current_count -ge $target_count ]]; then
        log_warn "Already have $current_count signers (target: $target_count). No new keys needed."
        log_info "Proceeding with rebalance only..."
    fi

    # Generate new keys if needed
    local -a new_keys=()
    local keys_to_generate=$((target_count - current_count))

    if [[ $keys_to_generate -gt 0 ]]; then
        log_info "Generating $keys_to_generate new keys..."
        echo ""

        for ((i=1; i<=keys_to_generate; i++)); do
            local wallet_output=$(generate_wallet) 2>/dev/null
            local private_key=$(echo "$wallet_output" | awk '{print $2}') 2>/dev/null
            # Strip 0x prefix for storage consistency with existing keys
            new_keys+=("$(strip_0x "$private_key")")
        done
    fi

    # Combine all keys
    local -a all_keys=("${existing_keys[@]}" "${new_keys[@]}")

    # Display ALL keys for backup
    echo ""
    echo -e "${YELLOW}╔════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║  BACKUP THESE KEYS NOW - THEY WILL NOT BE SHOWN AGAIN!             ║${NC}"
    echo -e "${YELLOW}╚════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${CYAN}=== EXISTING KEYS (already deployed) ===${NC}"

    local idx=1
    local addr=""
    for key in "${existing_keys[@]}"; do
        addr=$(key_to_address "$key") || { log_error "Failed to get address for key: ${key:0:10}..."; continue; }
        print_key_for_backup $idx "$addr" "$key"
        idx=$((idx + 1))
    done

    if [[ ${#new_keys[@]} -gt 0 ]]; then
        echo ""
        echo -e "${GREEN}=== NEW KEYS (generated just now) ===${NC}"
        for key in "${new_keys[@]}"; do
            addr=$(key_to_address "$key") || { log_error "Failed to get address for key: ${key:0:10}..."; continue; }
            print_key_for_backup $idx "$addr" "$key"
            idx=$((idx + 1))
        done
    fi

    echo ""
    echo -e "${YELLOW}Total keys: ${#all_keys[@]}${NC}"
    echo ""

    # Confirmation prompt
    if [[ "$SKIP_CONFIRMATION" != "true" ]]; then
        echo -e "${RED}Have you backed up ALL the keys above?${NC}"
        echo -n "Type 'yes' to continue, anything else to abort: "
        read confirm
        if [[ "$confirm" != "yes" ]]; then
            log_error "Aborted. Please backup your keys first."
            exit 1
        fi
    fi

    # Proceed with fund redistribution
    redistribute_funds all_keys EXTRA_WALLETS

    # Update Fly secrets
    local keys_csv
    keys_csv="${(j:,:)all_keys}"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would set EVM_PRIVATE_KEY with ${#all_keys[@]} keys"
    else
        log_info "Updating Fly secrets for $app_name..."
        fly secrets set "EVM_PRIVATE_KEY=$keys_csv" -a "$app_name"
        log_success "Secrets updated"

        log_info "Restarting $app_name..."
        fly apps restart "$app_name"
        log_success "App restarted"
    fi

    echo ""
    log_success "Scale complete! $app_name now has ${#all_keys[@]} signers."
}

# Main rebalance function
do_rebalance() {
    local fly_toml=$1

    if [[ ! -f "$fly_toml" ]]; then
        log_error "fly.toml not found: $fly_toml"
        exit 1
    fi

    local app_name
    app_name=$(get_app_name "$fly_toml")
    log_info "App: $app_name (rebalance mode)"

    # Fetch existing keys
    local raw_keys
    raw_keys=$(fetch_existing_keys "$app_name")

    if [[ -z "$raw_keys" ]]; then
        log_error "No existing keys found for $app_name"
        exit 1
    fi

    local -a existing_keys=()
    while IFS= read -r key; do
        [[ -n "$key" ]] && existing_keys+=("$key")
    done < <(parse_keys_to_array "$raw_keys")

    log_info "Found ${#existing_keys[@]} existing signers"

    # Redistribute funds
    redistribute_funds existing_keys EXTRA_WALLETS

    log_success "Rebalance complete!"
}

# Redistribute funds evenly among all target accounts
redistribute_funds() {
    local target_keys_name=$1
    local extra_wallets_name=$2

    # Get arrays by name reference
    local -a target_keys=("${(P@)target_keys_name}")
    local -a extra_wallets=("${(P@)extra_wallets_name}")

    local -a all_sources=()
    local -a all_targets=()

    # Target keys are both sources and targets
    for key in "${target_keys[@]}"; do
        all_targets+=("$key")
        all_sources+=("$key")
    done

    # Extra wallets are sources only (will be drained)
    for key in "${extra_wallets[@]}"; do
        [[ -n "$key" ]] && all_sources+=("$key")
    done

    local target_count=${#all_targets[@]}

    if [[ $target_count -eq 0 ]]; then
        log_error "No target accounts to distribute to"
        exit 1
    fi

    # Calculate total balance
    log_info "Calculating balances..."
    typeset -A balances
    typeset -A addresses
    local total_wei=0

    for key in "${all_sources[@]}"; do
        local addr balance
        addr=$(key_to_address "$key")
        balance=$(get_balance_wei "$addr")
        balances[$key]=$balance
        addresses[$key]=$addr
        total_wei=$((total_wei + balance))

        local balance_eth
        balance_eth=$(cast from-wei "$balance" ether 2>/dev/null || echo "0")
        echo "  $addr: $balance_eth ETH"
    done

    # Calculate target per account (simple division - gas is negligible on Base)
    local per_account_wei=$((total_wei / target_count))

    local total_eth per_account_eth
    total_eth=$(cast from-wei "$total_wei" ether 2>/dev/null || echo "0")
    per_account_eth=$(cast from-wei "$per_account_wei" ether 2>/dev/null || echo "0")

    echo ""
    log_info "Total: $total_eth ETH"
    log_info "Target per account: $per_account_eth ETH"
    echo ""

    if [[ $per_account_wei -eq 0 ]]; then
        log_warn "Not enough ETH to distribute. Please fund the accounts first."
        return
    fi

    # Confirmation prompt
    if [[ "$SKIP_CONFIRMATION" != "true" ]]; then
        echo -e "${RED}Are you sure you want to continue?${NC}"
        echo -n "Type 'yes' to continue, anything else to abort: "
        read confirm
        if [[ "$confirm" != "yes" ]]; then
            log_error "Aborted."
            exit 1
        fi
    fi

    # First, drain extra wallets to first target
    if [[ ${#extra_wallets[@]} -gt 0 ]] && [[ -n "${extra_wallets[1]:-}" ]]; then
        log_info "Draining extra wallets to first target account..."
        local first_target_addr
        first_target_addr=$(key_to_address "${all_targets[1]}")

        # Leave a tiny amount for potential future gas (0.00001 ETH)
        local min_reserve=10000000000000

        for key in "${extra_wallets[@]}"; do
            [[ -z "$key" ]] && continue
            local balance=${balances[$key]}
            local addr=${addresses[$key]}

            if [[ $balance -gt $min_reserve ]]; then
                local send_amount=$((balance - min_reserve))
                log_info "Draining $addr -> $first_target_addr"
                send_eth "$key" "$first_target_addr" "$send_amount"
                # send_eth handles its own success/error logging
            fi
        done

        # Update balance of first target after draining
        balances[${all_targets[1]}]=$(get_balance_wei "$first_target_addr")
    fi

    # Now redistribute among targets
    log_info "Redistributing among target accounts..."

    # Find accounts that need funds and accounts that have excess
    local -a donors=()
    local -a receivers=()
    typeset -A needs
    typeset -A excess

    for key in "${all_targets[@]}"; do
        local balance=${balances[$key]}
        local diff=$((balance - per_account_wei))

        if [[ $diff -gt 0 ]]; then
            donors+=("$key")
            excess[$key]=$diff
        elif [[ $diff -lt 0 ]]; then
            receivers+=("$key")
            needs[$key]=$((-diff))
        fi
    done

    # Transfer from donors to receivers
    for receiver_key in "${receivers[@]}"; do
        local needed=${needs[$receiver_key]}
        local receiver_addr=${addresses[$receiver_key]}

        for donor_key in "${donors[@]}"; do
            local available=${excess[$donor_key]:-0}

            if [[ $available -le 0 ]]; then
                continue
            fi

            local to_send=$needed
            if [[ $to_send -gt $available ]]; then
                to_send=$available
            fi

            if [[ $to_send -gt 0 ]]; then
                local donor_addr=${addresses[$donor_key]}
                log_info "Transfer: $donor_addr -> $receiver_addr"

                if send_eth "$donor_key" "$receiver_addr" "$to_send"; then
                    # send_eth already logs success with tx hash
                    excess[$donor_key]=$((available - to_send))
                    needed=$((needed - to_send))
                    needs[$receiver_key]=$needed
                fi
                # send_eth already logs errors
            fi

            if [[ $needed -le 0 ]]; then
                break
            fi
        done
    done

    # Final balance check
    echo ""
    log_info "Final balances:"
    for key in "${all_targets[@]}"; do
        local addr=${addresses[$key]}
        local balance_eth
        balance_eth=$(get_balance_eth "$addr")
        echo "  $addr: $balance_eth ETH"
    done
}

# Parse command line arguments
parse_args() {
    if [[ $# -lt 2 ]]; then
        echo "Usage:"
        echo "  manage-signers.sh scale <fly.toml> [target-count] [options]"
        echo "  manage-signers.sh rebalance <fly.toml> [options]"
        echo ""
        echo "Options:"
        echo "  --extra-wallet <key>  Additional funding source (can be repeated)"
        echo "  --rpc-url <url>       Custom RPC endpoint"
        echo "  --dry-run             Show what would happen without making changes"
        echo "  --yes                 Skip backup confirmation prompt"
        echo ""
        echo "Examples:"
        echo "  ./scripts/manage-signers.sh scale fly.x402-preconf.toml 20"
        echo "  ./scripts/manage-signers.sh rebalance fly.x402.toml --extra-wallet 0xabc..."
        exit 1
    fi

    MODE=$1
    FLY_TOML=$2
    shift 2

    TARGET_COUNT=""

    # For scale mode, check if next arg is a number (target count)
    if [[ "$MODE" == "scale" ]] && [[ $# -gt 0 ]] && [[ "$1" =~ ^[0-9]+$ ]]; then
        TARGET_COUNT=$1
        shift
    fi

    while [[ $# -gt 0 ]]; do
        case $1 in
            --extra-wallet)
                EXTRA_WALLETS+=("$2")
                shift 2
                ;;
            --rpc-url)
                RPC_URL=$2
                shift 2
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --yes)
                SKIP_CONFIRMATION=true
                shift
                ;;
            *)
                log_error "Unknown option: $1"
                exit 1
                ;;
        esac
    done
}

main() {
    check_dependencies
    parse_args "$@"

    log_info "RPC URL: $RPC_URL"
    [[ "$DRY_RUN" == "true" ]] && log_warn "DRY-RUN MODE - no changes will be made"
    echo ""

    case $MODE in
        scale)
            do_scale "$FLY_TOML" "$TARGET_COUNT"
            ;;
        rebalance)
            do_rebalance "$FLY_TOML"
            ;;
        *)
            log_error "Unknown mode: $MODE (use 'scale' or 'rebalance')"
            exit 1
            ;;
    esac
}

main "$@"
