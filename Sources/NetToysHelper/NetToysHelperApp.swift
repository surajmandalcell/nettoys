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
        let runtime = NetToysHelperRuntime(owner: .standalone)
        var location: NetToysHelperLocationAccess?
        // launchd relaunches a login item that exits, so wait idle until work or the lock appears.
        while true {
            if let lock = try? NetToysProcessLock(),
               !NetToysConfigurationStore.load().backgroundRequests.isEmpty {
                if location == nil {
                    let access = await MainActor.run {
                        NetToysHelperLocationAccess { state in Task { await runtime.setSSIDAccess(state) } }
                    }
                    await MainActor.run { access.start() }
                    location = access
                }
                await runtime.run()
                withExtendedLifetime(lock) {}
            }
            try? await Task.sleep(for: .seconds(30))
        }
    }
}
