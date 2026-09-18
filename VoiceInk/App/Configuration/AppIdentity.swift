import Foundation

enum AppIdentity {
    static let applicationSupportDirectoryName: String = {
        #if LOCAL_BUILD
            "com.will.myvoice"
        #else
            "com.prakashjoshipax.VoiceInk"
        #endif
    }()
}
