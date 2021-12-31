import Result "mo:base/Result";
module {
    public type Callback = shared () -> async ();
    public func notify(callback : ?Callback) : async () {
        switch(callback) {
            case null   return;
            case (? cb) {ignore cb()};
        };
    };

    public type SalesPrice = {
        #ICP : {
            e8s : Nat64
        };
    };

    public type TokenMarketError = {
        #TokenAlreadyListed;
        #TokenNotListed;
        #NotYetImplemented;
        #InvalidParameters   : Text;
        #IncorrectAmountSent : {sent : SalesPrice; ask : SalesPrice};
    };

    public type Error = {
        #Unauthorized;
        #NotFound;
        #InvalidRequest;
        #AuthorizedPrincipalLimitReached : Nat;
        #Immutable;
        #FailedToWrite : Text;
        #MarketError : TokenMarketError;
    };
}