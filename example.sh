#!/usr/bin/env sh

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

bold() {
    tput bold
    echo $1
    tput sgr0
}

check() {
    if [ "$1" = "$2" ]; then
        echo "${GREEN}OK${NC}"
    else
        echo "${RED}NOK${NC}: expected ${2}, got ${1}"
        dfx -q stop > /dev/null 2>&1
        exit 1
    fi
}

bold "| Starting replica."
dfx -q start --background --clean > /dev/null 2>&1

bold "| Deploying canisters (this can take a while): \c"
dfx -q identity new "admin" > /dev/null 2>&1
dfx -q identity use "admin"
adminID="$(dfx identity get-principal)"
dfx -q deploy --no-wallet
dfx canister id nft > /dev/null 2>&1
hubID="$(dfx canister id nft)"
echo "${GREEN}DONE${NC}"

bold "| Initializing hub: \c"
check "$(dfx canister call nft init "(
    vec{}, 
    record{ name = \"aviate\"; symbol = \"av8\" }
)")" "()"
bold "| Checking contract metadata: \c"
check "$(dfx canister call nft getMetadata)" "(record { name = \"aviate\"; symbol = \"av8\" })"

bold "| Mint first NFT: \c"
check "$(dfx canister call nft mint "(record{
    contentType = \"\";
    payload     = variant{ Payload = vec{ 0x00 } };
    owner       = null;
    properties  = null;
    isPrivate   = false;
})")" "(\"0\")"

bold "| Check owner (hub) of new NFT: \c"
check "$(dfx canister call nft ownerOf "(\"0\")")" "(variant { ok = principal \"${hubID}\" })"

bold "| Transfer NFT to admin: \c"
check "$(dfx canister call nft transfer "(
    principal \"${adminID}\", \"0\"
)")" "(variant { ok })"

bold "| Check balance of admin: \c"
check "$(dfx canister call nft balanceOf "(
    principal \"${adminID}\"
)")" "(vec { \"0\" })"

dfx -q stop > /dev/null 2>&1
