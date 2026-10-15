import Foundation

final class ArtworkXMLParserDelegate: NSObject, XMLParserDelegate {
    var images: [PlexImageResource] = []

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let supportedElements: Set<String> = ["Image", "Photo", "Poster"]
        guard supportedElements.contains(elementName) else { return }

        let width = attributeDict["width"].flatMap(Int.init)
        let height = attributeDict["height"].flatMap(Int.init)
        let selected = attributeDict["selected"].flatMap { $0 == "1" ? true : ($0 == "0" ? false : nil) }
        let image = PlexImageResource(
            key: attributeDict["key"],
            provider: attributeDict["provider"],
            type: attributeDict["type"],
            url: attributeDict["url"],
            thumb: attributeDict["thumb"],
            selected: selected,
            width: width,
            height: height
        )
        images.append(image)
    }
}
