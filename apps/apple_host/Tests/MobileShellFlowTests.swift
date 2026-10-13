import Foundation

@main
struct MobileShellFlowTests {
    @MainActor static func main() throws {
        let fm=FileManager.default
        let root=fm.temporaryDirectory.appendingPathComponent("aether-mobile-shell-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let support=root.appendingPathComponent("Support")
        let games=root.appendingPathComponent("Games")
        let source=root.appendingPathComponent("demo.xp3")
        try Data("fixture".utf8).write(to: source)
        let shell=MobileShellState(supportRoot:support,gamesRoot:games,environment:[:])
        precondition(shell.requiredDocument == .privacy && !shell.canPlay)
        do { _=try shell.prepareDemo(source:source); preconditionFailure("unaccepted gate launched game") }
        catch { precondition(!fm.fileExists(atPath:games.path)) }
        shell.decline(); precondition(shell.declined && !shell.canPlay)
        shell.reviewAgain(); precondition(!shell.declined && shell.requiredDocument == .privacy)
        shell.acceptDocument(); precondition(shell.requiredDocument == .statement && !shell.canPlay)
        let relaunched=MobileShellState(supportRoot:support,gamesRoot:games,environment:[:])
        precondition(relaunched.requiredDocument == .statement)
        relaunched.acceptDocument(); precondition(relaunched.canPlay)
        let demo=try relaunched.prepareDemo(source:source)
        let contents = try Data(contentsOf:demo.appendingPathComponent("data.xp3"))
        let files = try fm.contentsOfDirectory(atPath:demo.path)
        let secondDemo = try relaunched.prepareDemo(source:source)
        precondition(contents == Data("fixture".utf8))
        precondition(files == ["data.xp3"])
        precondition(secondDemo == demo)
        let final=MobileShellState(supportRoot:support,gamesRoot:games,environment:[:])
        precondition(final.canPlay)
        // A file in place of Application Support makes the atomic acceptance fail.
        let blocked=root.appendingPathComponent("blocked")
        try Data().write(to:blocked)
        let failed=MobileShellState(supportRoot:blocked,gamesRoot:games,environment:[:])
        failed.acceptDocument()
        precondition(!failed.canPlay && failed.requiredDocument == .privacy && failed.error != nil)
        try Data("corrupt".utf8).write(to:final.legalStore.url)
        let corrupt=MobileShellState(supportRoot:support,gamesRoot:games,environment:[:])
        precondition(!corrupt.canPlay && corrupt.requiredDocument == .privacy)
        let bypass=MobileShellState(supportRoot:support,gamesRoot:games,environment:[LegalAgreement.bypassEnvironmentKey:"1"])
        #if DEBUG
        precondition(bypass.canPlay)
        #else
        precondition(!bypass.canPlay)
        #endif
        print("PASS mobile gate ordering, decline/review, persistence, failed writes, corrupt records, Demo staging and build-specific bypass")
    }
}
