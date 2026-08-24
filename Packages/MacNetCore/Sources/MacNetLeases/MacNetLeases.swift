import Foundation
import MacNetModels

// Populated in a later phase. Declared now so the module graph builds from Phase 1 onward.
enum MacNetLeasesModuleMarker {
    static let coreSchemaVersion = MacNetCoreInfo.schemaVersion
}
