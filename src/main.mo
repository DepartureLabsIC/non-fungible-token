import Array "mo:base/Array";
import Blob "mo:base/Blob";
import Buffer "mo:base/Buffer";
import Debug "mo:base/Debug";
import ExperimentalCycles "mo:base/ExperimentalCycles";
import Hash "mo:base/Text";
import HashMap "mo:base/HashMap";
import Iter "mo:base/Iter";
import Nat "mo:base/Nat";
import NftTypes "types";
import Http "httpTypes";
import Option "mo:base/Option";
import Prim "mo:⛔";
import Principal "mo:base/Principal";
import Result "mo:base/Result";
import Text "mo:base/Text";
import Time "mo:base/Time";
import Trie "mo:base/TrieSet";

shared({ caller = hub }) actor class Nft() = this {
    var MAX_RESULT_SIZE_BYTES = 1_000_000; //1MB Default
    var HTTP_STREAMING_SIZE_BYTES = 1_900_000;

    stable var CONTRACT_METADATA : NftTypes.ContractMetadata = {name = "none"; symbol = "none"};
    stable var INITALIZED : Bool = false;

    stable var TOPUP_AMOUNT = 2_000_000;
    stable var AUTHORIZED_LIMIT = 25;
    stable var BROKER_CALL_LIMIT = 25;
    stable var BROKER_FAILED_CALL_LIMIT = 25;

    stable var id = 0;
    stable var payloadSize = 0;

    stable var nftEntries : [(Text, NftTypes.Nft)] = [];
    let nfts = HashMap.fromIter<Text, NftTypes.Nft>(nftEntries.vals(), 10, Text.equal, Text.hash);

    stable var staticAssetsEntries : [(Text, NftTypes.StaticAsset)] = [];
    let staticAssets = HashMap.fromIter<Text, NftTypes.StaticAsset>(staticAssetsEntries.vals(), 10, Text.equal, Text.hash);

    stable var nftToOwnerEntries : [(Text, Principal)] = [];
    let nftToOwner = HashMap.fromIter<Text, Principal>(nftToOwnerEntries.vals(), 15, Text.equal, Text.hash);

    stable var ownerToNftEntries : [(Principal, [Text])] = [];
    let ownerToNft = HashMap.fromIter<Principal, [Text]>(ownerToNftEntries.vals(), 15, Principal.equal, Principal.hash);

    stable var authorizedEntries : [(Text, [Principal])] = [];
    let authorized = HashMap.fromIter<Text, [Principal]>(authorizedEntries.vals(), 15, Text.equal, Text.hash);
    
    stable var contractOwners : [Principal] = [hub];
    
    stable var messageBrokerCallback : ?NftTypes.EventCallback = null;
    stable var messageBrokerCallsSinceLastTopup : Nat = 0;
    stable var messageBrokerFailedCalls : Nat = 0;

    var stagedNftData = Buffer.Buffer<Blob>(0);
    var stagedAssetData = Buffer.Buffer<Blob>(0);

    system func preupgrade() {
        nftEntries := Iter.toArray(nfts.entries());
        staticAssetsEntries := Iter.toArray(staticAssets.entries());
        nftToOwnerEntries := Iter.toArray(nftToOwner.entries());
        ownerToNftEntries := Iter.toArray(ownerToNft.entries());
        authorizedEntries := Iter.toArray(authorized.entries());
    };

    system func postupgrade() {
        nftEntries := [];
        staticAssetsEntries := [];
        nftToOwnerEntries := [];
        ownerToNftEntries := [];
        authorizedEntries := [];
    };

    // Secure Functions
    public shared({caller = caller}) func init(owners : [Principal], metadata : NftTypes.ContractMetadata) : async () {
        assert not INITALIZED and caller == hub;
        contractOwners := Array.append(contractOwners, owners);
        CONTRACT_METADATA := metadata;
    };

    public query func getMetadata() : async NftTypes.ContractMetadata {
        return CONTRACT_METADATA;
    };

    public query func getTotalMinted() : async Nat {
        return nfts.size();
    };

    public shared({caller = caller}) func wallet_receive() : async () {
        ignore ExperimentalCycles.accept(ExperimentalCycles.available());
    };

    public shared ({caller = caller}) func mint(egg : NftTypes.NftEgg) : async Text {
        assert _isOwner(caller);
        return await _mint(egg)
    };

    public shared({caller = caller}) func writeStaged(data : NftTypes.StagedWrite) : async () {
        assert _isOwner(caller);

        switch (data) {
            case (#Init(v)) {
                stagedNftData := Buffer.Buffer<Blob>(v.size);
            };
            case (#Chunk({chunk = chunk; callback = callback})) {
                stagedNftData.add(chunk);
                ignore _fireAndForgetCallback(callback);
            };
        }
    };

    public shared ({caller = caller}) func getContractInfo() : async NftTypes.ContractInfo {
        assert _isOwner(caller);
        return _contractInfo();
    };

    public query ({caller = caller }) func listAssets() : async [(Text, Text, Nat)] {
        assert _isOwner(caller);
        let assets : [var (Text, Text, Nat)] = Array.init<(Text, Text, Nat)>(staticAssets.size(), ("","",0));

        var idx = 0;

        for ((k, v) in staticAssets.entries()) {
            var sum = 0;
            Iter.iterate<Blob>(v.payload.vals(), func(x, _) {sum += x.size()});
            assets[idx] := (k, v.contentType, sum);
            idx += 1;
        };

        return Array.freeze(assets);
    };

    public shared ({caller = caller}) func assetRequest(data : NftTypes.AssetRequest) : async (){
        assert _isOwner(caller);

        switch(data) {
            case(#Put(v)) {
                switch(v.payload) {
                    case(#Payload(data)) {
                        staticAssets.put(v.name, {contentType = v.contentType; payload = [data]});
                    };
                    case (#StagedData) {
                        staticAssets.put(v.name, {contentType = v.contentType; payload = stagedAssetData.toArray()});
                        stagedAssetData := Buffer.Buffer(0);
                    };
                };
            };
            case(#Remove({name = name; callback = callback})) {
                staticAssets.delete(name);
                ignore _fireAndForgetCallback(callback);
            };
            case(#StagedWrite(v)) {
                switch(v) {
                    case (#Init({size = size; callback = callback})) {
                        stagedAssetData := Buffer.Buffer(size);
                        ignore _fireAndForgetCallback(callback);
                    };
                    case (#Chunk({chunk = chunk; callback = callback})) {
                        stagedAssetData.add(chunk);
                         ignore _fireAndForgetCallback(callback);
                    };
                }
            }
        };
    };

    public func balanceOf(p : Principal) : async [Text] {
        return _balanceOf(p)
    };

    public shared func ownerOf(id : Text) : async NftTypes.OwnerOfResult {
        switch(nftToOwner.get(id)) {
            case (null) return #err(#NotFound);
            case (?v) return #ok(v);
        };
    };

    public shared ({caller = caller}) func transfer(transferRequest : NftTypes.TransferRequest) : async NftTypes.TransferResult {
        return await _transfer(caller, transferRequest);
    };

    public shared ({caller = caller}) func authorize(authorizeRequest : NftTypes.AuthorizeRequest) : async NftTypes.AuthorizeResult {
        return await _authorize(caller, authorizeRequest);
    };

    public shared ({caller = caller}) func updateContractOwners(updateOwnersRequest : NftTypes.UpdateOwnersRequest) : async NftTypes.UpdateOwnersResult {
        if (not _isOwner(caller)) {
            return #err(#Unauthorized);
        };

        switch(updateOwnersRequest.isAuthorized) {
            case (true) {_addOwner(updateOwnersRequest.user)};
            case (false) {_removeOwner(updateOwnersRequest.user)};
        };

        ignore _emitEvent({
            createdAt = Time.now();
            event = #ContractEvent(#ContractAuthorize({user = updateOwnersRequest.user; isAuthorized = updateOwnersRequest.isAuthorized}));
            topupAmount = TOPUP_AMOUNT;
            topupCallback = wallet_receive;
        });

        return #ok();
    };

    public shared func isAuthorized(id : Text, user : Principal) : async Bool {
        switch (_isAuthorized(user, id)) {
            case (#ok()) return true;
            case (_) return false;
        };
    };

    public shared func getAuthorized(id : Text) : async [Principal] {
        switch (authorized.get(id)) {
            case (?v) return v;
            case _ return [];
        };
    };

    public shared({caller = caller}) func tokenByIndex(id : Text) : async NftTypes.NftResult {
        switch(nfts.get(id)) {
            case null return #err(#NotFound);
            case (?v) {
                if (v.isPrivate) {
                    switch(_isAuthorized(caller, id) ) {
                        case (#err(v)) {
                            if (not _isOwner(caller)) return #err(v);
                        };
                        case _ {};
                    }
                };
                var payloadResult : NftTypes.PayloadResult = #Complete(v.payload[0]);

                if (v.payload.size() > 1) {
                    payloadResult := #Chunk({data = v.payload[0]; totalPages = v.payload.size(); nextPage = ?1});
                };

                return #ok({
                    contentType = v.contentType;
                    createdAt = v.createdAt;
                    id = id;
                    owner = _ownerOf(id);
                    payload = payloadResult;
                    properties = v.properties;
                });
            }
        }
    };

    public query ({caller = caller}) func tokenByIndexInsecure(id : Text) : async NftTypes.NftResult {
        switch(nfts.get(id)) {
            case null return #err(#NotFound);
            case (?v) {
                if (v.isPrivate) {
                    switch(_isAuthorized(caller, id) ) {
                        case (#err(v)) {
                            if (not _isOwner(caller)) return #err(v);
                        };
                        case _ {};
                    }
                };
                var payloadResult : NftTypes.PayloadResult = #Complete(v.payload[0]);

                if (v.payload.size() > 1) {
                    payloadResult := #Chunk({data = v.payload[0]; totalPages = v.payload.size(); nextPage = ?1});
                };

                return #ok({
                    contentType = v.contentType;
                    createdAt = v.createdAt;
                    id = id;
                    owner = _ownerOf(id);
                    payload = payloadResult;
                    properties = v.properties;
                });
            }
        }
    };
    
    public shared ({caller = caller}) func tokenChunkByIndex(id : Text, page : Nat) : async NftTypes.ChunkResult {
        switch (nfts.get(id)) {
            case null return #err(#NotFound);
            case (?nft) {
                if (nft.isPrivate) {
                    switch(_isAuthorized(caller, id)) {
                        case (#err(v)) {
                            if (not _isOwner(caller)) return #err(v);
                        };
                        case _ {};
                    }; 
                };

                let totalPages = nft.payload.size();
                if (page > totalPages) {
                    return #err(#InvalidRequest);
                };

                var nextPage : ?Nat = null;
                if (totalPages > page + 1) {
                    nextPage := ?(page + 1);
                };

                #ok({
                    data = nft.payload[page];
                    nextPage = nextPage;
                    totalPages = totalPages;
                })

            };
        };
    };

    public query ({caller = caller}) func tokenChunkByIndexInsecure(id : Text, page : Nat) : async NftTypes.ChunkResult {
        switch (nfts.get(id)) {
            case null return #err(#NotFound);
            case (?nft) {
                if (nft.isPrivate) {
                    switch(_isAuthorized(caller, id)) {
                        case (#err(v)) {
                            if (not _isOwner(caller)) return #err(v);
                        };
                        case _ {};
                    }; 
                };

                let totalPages = nft.payload.size();
                if (page > totalPages) {
                    return #err(#InvalidRequest);
                };

                var nextPage : ?Nat = null;
                if (totalPages > page + 1) {
                    nextPage := ?(page + 1);
                };

                #ok({
                    data = nft.payload[page];
                    nextPage = nextPage;
                    totalPages = totalPages;
                })

            };
        };
    };

    public shared ({caller = caller}) func updateProperties(request : NftTypes.UpdatePropertyRequest) : async () {
        assert _isOwner(caller); // TODO update to result object
        switch(nfts.get(request.id)) {
            case null return;
            case (?nft) {

            };
        };
    };

    private func _handlePropertyUpdates(prop : NftTypes.Property, request : [NftTypes.UpdateQuery]) : NftTypes.Property {
        for (q in request.vals()) {
            
        };
        return prop;
    };

    private func _handleUpdateQuery(prop : NftTypes.Property, q : NftTypes.UpdateQuery) : NftTypes.Property {
        if (q.name != prop.name) return prop;
        switch(q.mode) {
            case (#Next(v)) {
                return _handlePropertyUpdates(prop, v);
            };
            case (#Set(v)) {
                if (prop.immutable) return prop; // Throw
                return {
                    name = prop.name;
                    immutable = false;
                    value = v;
                }
            };
        };
    };

    // Insecure Functions
    public shared query func balanceOfInsecure(p : Principal) : async [Text] {
        return _balanceOf(p)
    };

    public shared query func ownerOfInsecure(id : Text) : async NftTypes.OwnerOfResult {
        switch(nftToOwner.get(id)) {
            case (null) return #err(#NotFound);
            case (?v) return #ok(v);
        };
    };

    public shared query func isAuthorizedInsecure(id : Text, user : Principal) : async Bool {
        switch (_isAuthorized(user, id)) {
            case (#ok()) return true;
            case (_) return false;
        };
    };

    public query func getAuthorizedInsecure(id : Text) : async [Principal] {
        switch (authorized.get(id)) {
            case (?v) return v;
            case _ return [];
        };
    };

    public query ({caller = caller}) func getContractInfoInsecure() : async NftTypes.ContractInfo {
        assert _isOwner(caller);
        return _contractInfo();
    };

    public query ({caller = caller}) func queryProperties(propertyQuery : NftTypes.PropertyQueryRequest) : async NftTypes.PropertyQueryResult {
        switch(propertyQuery.mode) {
            case (#All) {
                switch(nfts.get(propertyQuery.id)) {
                    case (null) {return #err(#NotFound)};
                    case (?v) {
                        if (v.isPrivate) {
                            switch(_isAuthorized(caller, propertyQuery.id)) {
                                case (#err(v)) return #err(v);
                                case _ {};
                            };
                        };
                        switch(v.properties) {
                            case null {return #ok(null)};
                            case (?properties) {
                                return #ok(?properties)
                            }
                        }
                    };
                }
            };
            case (#Some(v)) {
                return  _handleQueries(caller, propertyQuery.id, v);
            };
        };
    };

    private func _handleQueries(caller : Principal, id : Text, query0 : NftTypes.PropertyQuery) : NftTypes.PropertyQueryResult {
        switch(nfts.get(id)) {
            case (null) return #err(#NotFound);
            case (?nft) {
                if (nft.isPrivate) {
                    switch(_isAuthorized(caller, id)) {
                        case (#err(v)) {
                            if (not _isOwner(caller)) return #err(v);
                        };
                        case (v) {};
                    }
                };
                switch (nft.properties) {
                    case null {return #ok(?{immutable = true; value = #Empty; name = query0.name})};
                    case (?properties) {
                        switch(_handleQuery(properties, query0)){
                            case null {return #ok(null)};
                            case (?v) {return #ok(?v)}
                        };
                    }
                }
            };
        }
    };

    private func _handleQuery(klass : NftTypes.Property, query0 : NftTypes.PropertyQuery) : ?NftTypes.Property {
        if (klass.name == query0.name) {
                switch(query0.next) {
                    case null {
                        return ?{name = klass.name; value = klass.value; immutable = klass.immutable};
                    };
                    case (?vals) {
                        switch(klass.value) {
                            case (#Class(nestedClass)) {
                                var foundProps : [NftTypes.Property] = [];
                                for (next : NftTypes.PropertyQuery in vals.vals()) {
                                    for (prop in nestedClass.vals()) {
                                        switch(_handleQuery(prop, next)) {
                                            case(null){};
                                            case(?v){
                                                foundProps := Array.append(foundProps, [v]);
                                            };
                                        };
                                    };
                                };
                                return ?{name = klass.name; value = #Class(foundProps); immutable = klass.immutable}
                            };
                            case (_) {
                            }; // Only Class has nested props
                        }
                    }
                }
        };
        return null;
    };

    // Internal Functions
    private func _balanceOf(p : Principal) : [Text] {
        switch (ownerToNft.get(p)) {
            case (?v) return v;
            case (null) return [];
        };
    };

    private func _mint(egg : NftTypes.NftEgg) : async Text {
        let thisId = Nat.toText(id);
        
        var size = 0;
        switch (egg.payload) {
            case (#Payload(v)) {
                nfts.put(thisId, {
                    contentType = egg.contentType;
                    createdAt = Time.now();
                    payload = [v];
                    properties = egg.properties;
                    isPrivate = egg.isPrivate;
                 });
                 size := v.size();
            };
            case (#StagedData) {
                nfts.put(thisId, {
                    contentType = egg.contentType;
                    createdAt = Time.now();
                    payload = stagedNftData.toArray();
                    properties = egg.properties;
                    isPrivate = egg.isPrivate;
                });
                for (x in stagedNftData.vals()) {
                    size := size + x.size();
                };
                stagedNftData := Buffer.Buffer(0);
            };
        };

        payloadSize := payloadSize + size;

        id := id + 1;

        var owner = Principal.fromActor(this);

        switch (egg.owner) {
            case (null) {};
            case (?v) {
                owner := v;
           };
        };

        MAP_HELPER.add<Principal, Text>(ownerToNft, owner, thisId, func (v : Text) : Bool { v == thisId});
        nftToOwner.put(thisId, owner);

        ignore _emitEvent({
            createdAt = Time.now();
            event = #ContractEvent(#Mint({id = thisId; owner = owner}));
            topupAmount = TOPUP_AMOUNT;
            topupCallback = wallet_receive;
        });

        return thisId;
    };

    private func _contractInfo() : NftTypes.ContractInfo {
        return {
            heapSize = Prim.rts_heap_size();
            memorySize = Prim.rts_memory_size();
            maxLiveSize = Prim.rts_max_live_size();
            nftPayloadSize = payloadSize;
            totalMinted = nfts.size();
            cycles = ExperimentalCycles.balance();
            authorizedUsers = contractOwners;
        };
    };

    private func _fireAndForgetCallback(cbMaybe : ?NftTypes.Callback) : async () {
        switch(cbMaybe) {
            case null return;
            case (?cb) {ignore cb()};
        };
    };

    private func _ownerOf(id : Text) : Principal {
        switch(nftToOwner.get(id)) {
            case (null) return Principal.fromActor(this);
            case (?v) return v;
        }
    };

    private func _isOwner(p : Principal) : Bool {
        switch(Array.find<Principal>(contractOwners, func(v) {return v == p})) {
            case (null) return false;
            case (?v) return true;
        };
    };

    private func _addOwner(p : Principal) {
        if (_isOwner(p)) {
            return;
        };
        contractOwners := Array.append(contractOwners, [p]);
    };

    private func _removeOwner(p : Principal) {
        contractOwners := Array.filter<Principal>(contractOwners, func(v) {v != p});
    };

    // Check auth
    // Update owners
    // Remove existing auths
    private func _transfer(caller : Principal, transferRequest : NftTypes.TransferRequest) : async NftTypes.TransferResult {
        switch(nfts.get(transferRequest.id)) {
            case null return #err(#NotFound);
            case (?v) {}; // Nft Exists
        };

        var tokenOwner = Principal.fromActor(this);

        switch (nftToOwner.get(transferRequest.id)) {
            case null {
            };
            case (?realOwner) {
                tokenOwner := realOwner;
                if (tokenOwner == transferRequest.to) {
                    return #err(#InvalidRequest);
                };
            }
        };

        let isOwnedContractAndCallerOwner = tokenOwner == Principal.fromActor(this) and _isOwner(caller);
        
        if (caller != tokenOwner and not isOwnedContractAndCallerOwner) {
            switch(authorized.get(transferRequest.id)) {
                case null return #err(#Unauthorized);
                case (?users) {
                    switch(Array.find<Principal>(users, func (v : Principal) {return v == caller})) {
                        case null return #err(#Unauthorized);
                        case (?_) {};
                    };
                };
            };
        };

        MAP_HELPER.add<Principal, Text>(ownerToNft, transferRequest.to, transferRequest.id, func (v : Text) : Bool { v == transferRequest.id});
        MAP_HELPER.remove<Principal, Text>(ownerToNft, tokenOwner, transferRequest.id, func (v : Text) : Bool { v != transferRequest.id});

        nftToOwner.put(transferRequest.id, transferRequest.to);
        authorized.put(transferRequest.id, []);
        
        ignore _emitEvent({
            createdAt = Time.now();
            event = #NftEvent(#Transfer({from = tokenOwner; to = transferRequest.to; id = transferRequest.id}));
            topupAmount = TOPUP_AMOUNT;
            topupCallback = wallet_receive;
        });

        return #ok();
    };

    private func _authorize(caller : Principal, r : NftTypes.AuthorizeRequest) : async NftTypes.AuthorizeResult {
        switch(_isAuthorized(caller, r.id)) {
            case (#err(v)) { return #err(v)};
            case (_) {} // Ok;
        };

        switch(r.isAuthorized) {
            case (true) {
                switch(MAP_HELPER.addIfNotLimit<Text, Principal>(authorized, r.id, r.user, AUTHORIZED_LIMIT, func (v : Principal) {v == r.user})) {
                    case true {};
                    case false {return #err(#AuthorizedPrincipalLimitReached(AUTHORIZED_LIMIT))};
                };
            };
            case (false) {
                MAP_HELPER.remove<Text, Principal>(authorized, r.id, r.user, func (v : Principal) {v != r.user});
            };
        };
        ignore _emitEvent({
            createdAt = Time.now();
            event = #NftEvent(#Authorize({id = r.id; user = r.user; isAuthorized = r.isAuthorized}));
            topupAmount = TOPUP_AMOUNT;
            topupCallback = wallet_receive;
        });
        return #ok();
    };

    private func _emitEvent(event : NftTypes.EventMessage) : async () {
        let emit = func(broker : NftTypes.EventCallback, msg : NftTypes.EventMessage) : async () {
            try {
                await broker(msg);
                messageBrokerCallsSinceLastTopup := messageBrokerCallsSinceLastTopup + 1;
                messageBrokerFailedCalls := 0;
            } catch(_) {
                messageBrokerFailedCalls := messageBrokerFailedCalls + 1;
                if (messageBrokerFailedCalls > BROKER_FAILED_CALL_LIMIT) {
                    messageBrokerCallback := null;
                };
            };
        };

        switch(messageBrokerCallback) {
            case null return;
            case (?broker) {
                if (messageBrokerCallsSinceLastTopup > BROKER_CALL_LIMIT) {return};
                ignore emit(broker, event);
            };
        };
    };

    private func _isAuthorized(caller : Principal, id : Text) : Result.Result<(), NftTypes.Error> {
        switch (nfts.get(id)) {
            case null return #err(#NotFound);
            case _ {};
        };
        
        switch (nftToOwner.get(id)) {
            case null {}; // Not owner. Check if authd
            case (?v) {
                if (v == caller) return #ok(); 

                if (v == Principal.fromActor(this)) { // Owner is contract
                    if (_isOwner(caller)) {
                        return #ok();
                    };
                };
            };
        };

        switch(authorized.get(id)) {
                case null return #err(#Unauthorized);
                case (?users) {
                    switch(Array.find<Principal>(users, func (v : Principal) {return v == caller})) {
                        case null return #err(#Unauthorized);
                        case (?user) {
                            return #ok() // is Authd!
                        };
                    };
                };
        };

        return #err(#Unauthorized);
    };

    let MAP_HELPER = module {
        public func add<K, V>(map : HashMap.HashMap<K, [V]>, k : K, v : V, f : V -> Bool) {
            switch(map.get(k)) {
                case null {map.put(k, [v])};
                case (?existing) {
                    switch(Array.find<V>(existing, f)) {
                        case null {
                            map.put(k, Array.append(existing, [v]));
                        };
                        case (?v) {}; // exists do nothing..
                    }
                };
            };
        };
        
        public func addIfNotLimit<K, V>(map : HashMap.HashMap<K, [V]>, k : K, v : V, limit : Nat, f : V -> Bool) : Bool {
            switch(map.get(k)) {
                case null {map.put(k, [v])};
                case (?existing) {
                    if (existing.size() >= limit) {
                        return false;
                    };
                    switch(Array.find<V>(existing, f)) {
                        case null {
                            map.put(k, Array.append(existing, [v]));
                        };
                        case (?v) {}; // exists do nothing..
                    }
                };
            };
            return true;
        };

        public func remove<K, V>(map : HashMap.HashMap<K, [V]>, k : K, v : V, f : V -> Bool) {
            switch(map.get(k)) {
                case null {};
                case (?existing) {
                    let new = Array.filter<V>(existing, f);
                    if (new.size() > 0) {
                        map.put(k, new);
                    } else {
                        map.delete(k);
                    }
                };
            };
        }
    };

    public shared ({caller = caller}) func setEventCallback(cb : NftTypes.EventCallback) : async () {
        assert _isOwner(caller);
        messageBrokerCallback := ?cb;
    };

    public shared ({caller = caller}) func getEventCallbackStatus() : async NftTypes.EventCallbackStatus {
        assert _isOwner(caller);
        return {
            callback = messageBrokerCallback;
            callsSinceLastTopup = messageBrokerCallsSinceLastTopup;
            failedCalls = messageBrokerFailedCalls;
            noTopupCallLimit = BROKER_CALL_LIMIT;
            failedCallsLimit = BROKER_FAILED_CALL_LIMIT;
        };
    };

    // Http Interface

    let NOT_FOUND : Http.Response = {statusCode = 404; headers = []; body = Blob.fromArray([]); streamingStrategy = null};
    let BAD_REQUEST : Http.Response = {statusCode = 400; headers = []; body = Blob.fromArray([]); streamingStrategy = null};
    let UNAUTHORIZED : Http.Response = {statusCode = 401; headers = []; body = Blob.fromArray([]); streamingStrategy = null};

    public query func http_request(request : Http.Request) : async Http.Response {
        Debug.print(request.url);
        let path = Iter.toArray(Text.tokens(request.url, #text("/")));
        
        if (path.size() == 0) {
            return _handleAssets("/index.html");
        };

        if (path[0] == "nft") {
            if (path.size() == 1) {
                return BAD_REQUEST;
            };
            return _handleNft(path[1]);
        };

        return _handleAssets(request.url);     
    };

    private func _handleAssets(path : Text) : Http.Response {
        Debug.print("Handling asset " # path);
        switch(staticAssets.get(path)) {
            case null {
                if (path == "/index.html") return NOT_FOUND;
                return _handleAssets("/index.html");
            };
            case (?asset) {
                if (asset.payload.size() > 1) {
                    return _handleLargeContent(path, asset.contentType, asset.payload);
                } else {
                    return {
                        body = asset.payload[0];
                        headers = [("Content-Type", asset.contentType)];
                        statusCode = 200;
                        streamingStrategy = null;
                    };
                }
            }
        };
    };

    private func _handleNft(id : Text) : Http.Response {
        Debug.print("Here c");
        switch(nfts.get(id)) {
            case null return NOT_FOUND;
            case (?nft) {
                if (nft.isPrivate) {return UNAUTHORIZED};
                if (nft.payload.size() > 1) {
                    return _handleLargeContent(id, nft.contentType, nft.payload);
                } else {
                    return {
                        statusCode = 200;
                        headers = [("Content-Type", nft.contentType)];
                        body = nft.payload[0];
                        streamingStrategy = null;
                    }
                }
            };
        }
    };

    private func _handleLargeContent(id : Text, contentType : Text, data : [Blob]) : Http.Response {
        Debug.print("Here b");
        let (payload, token) = _streamContent(id, 0, data);

        return {
            statusCode = 200;
            headers = [("Content-Type", contentType)];
            body = payload;
            streamingStrategy = ? #Callback({
                token = Option.unwrap(token);
                callback = httpRequestStreamingCallback;
            });
        };
    };

    public query func httpRequestStreamingCallback(token : Http.StreamingCallbackToken) : async Http.StreamingCallbackResponse {
        switch(nfts.get(token.key)) {
            case null return {body = Blob.fromArray([]); token = null};
            case (?v) {
                if (v.isPrivate) {return {body = Blob.fromArray([]); token = null}};
                let res = _streamContent(token.key, token.index, v.payload);
                return {
                    body = res.0;
                    token = res.1;
                }
            }
        }
    };

    private func _streamContent(id : Text, idx : Nat, data : [Blob]) : (Blob, ?Http.StreamingCallbackToken) {
        let payload = data[idx];
        let size = data.size();

        if (idx + 1 == size) {
            return (payload, null);
        };

        return (payload, ?{
            contentEncoding = "gzip";
            index = idx + 1;
            sha256 = null;
            key = id;
        });
    };
}