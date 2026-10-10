import Foundation

struct PlatformPurchaseResponse {
    let productID: String
    let argument: String
    static func unavailable(productID: String) -> PlatformPurchaseResponse {
        let escaped = productID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return PlatformPurchaseResponse(productID: productID,
            argument: "result=-1&title=&description=&price=&token=&error_response=-1&error_message=In%20App%20Billing%20is%20unavailable&product_id=\(escaped)")
    }
}

struct PlatformPurchaseRequest {
    let productID: String
    init(argument: String) {
        let fields = argument.split(separator: "&", omittingEmptySubsequences: true)
        var value = ""
        for field in fields {
            let parts = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0] == "product_id" else { continue }
            value = parts[1].replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(parts[1])
            break
        }
        productID = value
    }
}
