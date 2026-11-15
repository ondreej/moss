import Testing
import MossCore
@testable import MossSettings

@Suite("Descriptions")
struct DescribingTests {
    @Test(arguments: [
        ("open -na Terminal", "Open Terminal"),
        ("[float] open -a \"Visual Studio Code\"", "Open Visual Studio Code"),
        ("open ~", "Open the home folder"),
        ("open ~/Downloads", "Open Downloads"),
        ("say hello", "Run say hello"),
    ])
    func commands(command: String, description: String) {
        #expect(Describe.launchDescription(command) == description)
    }
}
