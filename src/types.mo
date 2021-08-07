import Result "mo:base/Result";
module {
    public type ContractMetadata = {
        name : Text;
        symbol : Text;
    };

    public type EventCallbackStatus = {
        callback : ?EventCallback;
        callsSinceLastTopup : Nat;
        noTopupCallLimit : Nat;
        failedCalls : Nat;
        failedCallsLimit : Nat;
    };

    public type Error = {
        #Unauthorized;
        #NotFound;
        #InvalidRequest;
        #AuthorizedPrincipalLimitReached : Nat;
    };

    public type TransferRequest = {
        to : Principal;
        id : Text;
    };

    public type AuthorizeRequest = {
        id : Text;
        user : Principal;
        isAuthorized : Bool;
    };

    public type UpdateOwnersRequest = {
        user : Principal;
        isAuthorized : Bool;
    };

    public type PayloadResult = {
        #Complete : Blob;
        #Chunk : Chunk;
    };

    public type TransferResult = Result.Result<(), Error>;
    public type AuthorizeResult = Result.Result<(), Error>;
    public type UpdateOwnersResult = Result.Result<(), Error>;
    public type PropertyQueryResult = Result.Result<?Property, Error>;
    public type NftResult = Result.Result<PublicNft, Error>;
    public type OwnerOfResult = Result.Result<Principal, Error>;

    public type Chunk = {data : Blob; nextPage : ?Nat; totalPages : Nat};

    public type ChunkResult = Result.Result<Chunk, Error>;

    public type Nft = {
        payload : [Blob];
        contentType : Text;
        createdAt: Int;
        properties : ?Property;
        isPrivate : Bool;
    };

    public type NftEgg = {
        payload : {
            #Payload : Blob;
            #StagedData;
        };
        contentType : Text;
        owner : ?Principal;
        properties : ?Property;
        isPrivate : Bool;
    };

    public type PublicNft = {
        id : Text;
        payload : PayloadResult;
        contentType : Text;
        owner : Principal;
        createdAt: Int;
        properties : ?Property;
    };

    public type NftEvent = {
        #Transfer : {id : Text; from : Principal; to : Principal};
        #Authorize : {id : Text; user : Principal; isAuthorized: Bool};
    };

    public type ContractEvent = {
        #ContractAuthorize : {user : Principal; isAuthorized: Bool};
        #Mint : {id : Text; owner : Principal};
    };

    public type EventCallback = shared (msg : EventMessage) -> async ();
    public type TopupCallback = shared () -> async ();

    public type EventMessage = {
        createdAt : Int;
        event : {
            #ContractEvent : ContractEvent;
            #NftEvent : NftEvent;
        };
        topupCallback : TopupCallback;
        topupAmount : Nat;
    };

    public type StaticAsset = {
        contentType : Text;
        payload : [Blob];
    };
    public type ContractInfo = {
        heapSize : Nat;
        memorySize : Nat;
        maxLiveSize : Nat;
        nftPayloadSize : Nat;
        totalMinted : Nat;
        cycles : Nat;
        authorizedUsers : [Principal];
    };
    
    public type StagedWrite = {
        #Init : {size : Nat; callback : ?Callback};
        #Chunk : {chunk : Blob; callback : ?Callback};
    };

    public type Callback = shared () -> async ();

    public type AssetRequest = {
        #Remove : {name : Text; callback : ?Callback};
        #Put : {name : Text; contentType : Text; payload : {#Payload : Blob; #StagedData}; callback : ?Callback};
        #StagedWrite : StagedWrite;
    };

    public type Value = {
        #Int : Int; 
        #Nat : Nat;
        #Float : Float;
        #Text : Text; 
        #Bool : Bool; 
        #Class : [Property]; 
        #Principal : Principal;
        #Empty;
    }; 

    public type UpdatedValue = {
        #Int : Int; 
        #Nat : Nat;
        #Float : Float;
        #Text : Text; 
        #Bool : Bool; 
        #Principal : Principal;
    }; 

    // TODO -> Consider supporting functions
    // TODO -> This can be extended to support DSL lmao

    public type Property = {name : Text; value : Value; immutable : Bool};

    public type PropertyQuery = {
        name : Text;
        next : ?[PropertyQuery];        
    };

    public type PropertyQueryRequest = {
        id : Text;
        mode : {#All; #Some : PropertyQuery};
    };

    public type UpdateQuery = {
        name : Text;
        mode : {
            #Next : [UpdateQuery]; 
            #Set : UpdatedValue;
        };
    };

    public type UpdatePropertyRequest = {
        id : Text;
        updateQuery : [UpdateQuery];
    };
}