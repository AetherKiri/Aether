import Foundation

@main
struct PlatformPurchaseTests {
    static func main() {
        let request = PlatformPurchaseRequest(argument: "product_id=com.aether.coffee")
        precondition(request.productID == "com.aether.coffee")
        let encoded = PlatformPurchaseRequest(argument: "product_id=com.aether.coffee%2Bbeta").productID
        precondition(encoded == "com.aether.coffee+beta")
        let missing = PlatformPurchaseRequest(argument: "title=coffee")
        precondition(missing.productID.isEmpty)
        let response = PlatformPurchaseResponse.unavailable(productID: request.productID)
        precondition(response.argument.contains("result=-1&title=&description=&price=&token="))
        precondition(response.argument.contains("error_response=-1&error_message=In%20App%20Billing%20is%20unavailable"))
        precondition(response.argument.hasSuffix("product_id=com.aether.coffee"))
        print("PASS: purchase request parsing and deterministic unsupported response")
    }
}
