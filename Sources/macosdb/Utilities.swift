import Foundation
import macOSdbKit

nonisolated func makeDataProvider(dataURL: String?) -> DataProvider {
    if let dataURL, let url = URL(string: dataURL) {
        return DataProvider(baseURL: url)
    }
    return DataProvider()
}
