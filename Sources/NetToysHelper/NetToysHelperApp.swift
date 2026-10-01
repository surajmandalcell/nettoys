import Darwin
import Foundation
import NetToysCore

@main
struct NetToysHelperApp {
    static func main() async {
        if CommandLine.arguments == [CommandLine.arguments[0], "--verify-resources"] {
            do { try NetToysBuild.verifyBundledResources(); print("NetToys resources verified"); return }
            catch { FileHandle.standardError.write(Data("NetToys resources are missing\n".utf8)); exit(1) }
        }
        if geteuid() == 0 { NetToysNeighborDaemon.run() }
        guard let lock = try? NetToysProcessLock(),
              !NetToysConfigurationStore.load().backgroundRequests.isEmpty else { return }
        let runtime = NetToysHelperRuntime(owner: .standalone)
        let location = await MainActor.run {
            NetToysHelperLocationAccess { state in Task { await runtime.setSSIDAccess(state) } }
        }
        await MainActor.run { location.start() }
        await runtime.run()
        withExtendedLifetime(lock) {}
    }
}
