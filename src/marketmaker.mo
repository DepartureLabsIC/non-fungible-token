import HashMap "mo:base/HashMap";
import Iter "mo:base/Iter";
import Result "mo:base/Result";
import Text "mo:base/Text";
import Types "types";

module MarketMaker {
    public type TokenMarketMeta = {

    };

    public type TokenMarketState = {
        #BuyItNow : {
            price : Types.SalesPrice; 
            meta  : TokenMarketState;
        };
    };

    public class MarketMaker(tokenStateEntries : [(Text, TokenMarketState)]) {
        let tokenStates = HashMap.HashMap<Text, TokenMarketState>(tokenStateEntries.size(), Text.equal, Text.hash);
        
        public func isListed(tokenId : Text) : Bool {
            switch(tokenStates.get(tokenId)) {
                case null false;
                case (?_) true;
            };
        };

        public func listToken(tokenId : Text, listingType : TokenMarketState) : Result.Result<(), Types.TokenMarketError> {
            switch (tokenStates.get(tokenId)) {
                case (?_) {return #err(#TokenAlreadyListed)};
                case null {
                    tokenStates.put(tokenId, listingType);
                    return #ok();
                };
            };
        };

        public func delistToken(tokenId : Text) : Result.Result<(), Types.TokenMarketError> {
            tokenStates.delete(tokenId);
            #ok();
        };

        public func handleIncomingPayment(tokenId : Text, purchaser : Principal, amount : Types.SalesPrice) : Result.Result<(), Types.TokenMarketError> {
            switch(tokenStates.get(tokenId)) {
                case null {return #err(#TokenNotListed)};
                case (?tokenState) {
                    switch(tokenState) {
                        case (#BuyItNow(v)) {
                            if (v.price != amount) {
                                return #err(#IncorrectAmountSent({sent = amount; ask = v.price}));
                            };

                            return #ok();
                        };
                    };
                };
            };
            return #err(#NotYetImplemented);
        };

        public func entries() : Iter.Iter<(Text, TokenMarketState)> {
            return tokenStates.entries();
        };
    };
}