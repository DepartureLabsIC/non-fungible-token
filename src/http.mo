import Blob "mo:base/Blob";
import HashMap "mo:base/HashMap";
import Option "mo:base/Option";

module Http {
    public type Request = {
        body: Blob;
        headers: [HeaderField];
        method: Text;
        url: Text;
    };

    public type HeaderField = (Text, Text);

    public type Response = {
        body: Blob;
        headers: [HeaderField];
        status_code: Nat16;
        streaming_strategy: ?StreamingStrategy;
    };

    public type StreamingCallbackToken =  {
        content_encoding: Text;
        index: Nat;
        key: Text;
    };

    public type StreamingStrategy = {
        #Callback: {
            callback: StreamingCallback;
            token: StreamingCallbackToken;
        };
    };

    public type StreamingCallback = query (StreamingCallbackToken) -> async (StreamingCallbackResponse);

    public type StreamingCallbackResponse = {
        body: Blob;
        token: ?StreamingCallbackToken;
    };

    public func BAD_REQUEST()  : Response = error(400);
    public func UNAUTHORIZED() : Response = error(401);
    public func NOT_FOUND()    : Response = error(404);

    private func error(statusCode : Nat16) : Response = {
        status_code = statusCode;
        headers = [];
        body = Blob.fromArray([]);
        streaming_strategy = null;
    };

    // Returns the first chunk of the payload and a callback for the next.
    public func handleLargeContent(
        key : Text,
        contentType : Text,
        data : [Blob],
        callback: StreamingCallback,
    ) : Response {
        let (payload, token) = streamContent(key, 0, data);
        return {
            status_code = 200;
            headers = [("Content-Type", contentType)];
            body = payload;
            streaming_strategy = ?#Callback({
                token = Option.unwrap(token); // Callback token.
                callback = callback;
            });
        };
    };

    // Returns the payload based on the given index.
    // Returns a callback token if the data is devided in chunks and the index is not the last one.
    //
    // @pre: idx < data.size()
    public func streamContent(
        key : Text,
        idx : Nat,
        data : [Blob],
    ) : (
        Blob,                        // Payload based on the index.
        ?Http.StreamingCallbackToken // Callback for next chunk (if applicable).
    ) {
        let payload = data[idx];
        if (idx + 1 == data.size()) return (payload, null);
        (payload, ?{
            content_encoding = "gzip";
            index = idx + 1;
            key = key;
        });
    };
};