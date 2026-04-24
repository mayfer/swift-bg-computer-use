import Foundation

func printJSON(_ object: Any) throws {
    let data = try JSONSerialization.data(withJSONObject: object, options: [])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0a]))
}
