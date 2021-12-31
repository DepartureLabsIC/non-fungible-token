import Array "mo:base/Array";
import MarketMaker "../marketmaker";
import Option "mo:base/Option";

module {
    	// Value being send in transaction
	public type Value = {
		#ICP : {e8s : Nat64};
	};

	public type MetadataValue = {
		#Nat       : Nat;
		#Int       : Int;
		#Text      : Text;
		#Principal : Principal;
	};

	public type MetadataKey = Text;
	public type MetadataItem = (MetadataKey, MetadataValue);
	public type MetadataValues = [MetadataItem];

	public type Notification = {
		metadata       : MetadataValues;
		amount         : Value;
		receivedAt     : Int; // Nanos
		currentBalance : Value;
	};

	public type NotifiableResponse = {
		#Accept; // Accept the transaction
		#AcceptAndWithdraw : Nat64; // Accept and prompt quark to transfer funds to canister
		#Reject            : {reason : ?Text} // Reject and surface message to UI
	};

    public class QuarkPaymentProcessor(marketMaker : MarketMaker.MarketMaker) {

        public func handleNotification(event : Notification) :  NotifiableResponse {
            switch(extractTokenId(event.metadata)) {
                case null return #Reject({reason = ?"Invalid Request. Expected TokenId Metadata"});
                case (?tokenId) {
                    switch(extractOwner(event.metadata)) {
                        case null return #Reject({reason = ?"Invalid Request. Expected Owner Metadata"});
                        case (?owner) {
                            let marketMakerResult = marketMaker.handleIncomingPayment(tokenId, owner, event.amount);
                            switch(marketMakerResult) {
                                case (#err(v)) {
                                    return #Reject({reason = ?debug_show v}); // We need better error handling here
                                };
                                case (#ok) {
                                    return #Accept
                                };
                            };
                        };
                    };
                    #Reject({reason = ?"Unexpected"});
                };
            };            
        };

        private func extractTokenId(metadataItems : MetadataValues) : ?Text {
            switch(Array.find<MetadataItem>(metadataItems, func (v) { v.0 == "TokenId"})) {
                case null return null;
                case (?v) {
                    switch(v.1) {
                        case (#Text(tokenId)) {
                            return ?tokenId;
                        };
                        case _ return null;
                    };
                };
            };
        };

        private func extractOwner(metadataItems : MetadataValues) : ?Principal {
            switch(Array.find<MetadataItem>(metadataItems, func (v) { v.0 == "Owner"})) {
                case null return null;
                case (?v) {
                    switch(v.1) {
                        case (#Principal(owner)) {
                            return ?owner;
                        };
                        case _ return null;
                    };
                };
            };
        };
    };
}