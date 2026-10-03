import FirebaseAuth
import Foundation
import Testing
@testable import ParcelPilot

@Suite("Sign-in configuration and messages")
struct AuthTests {
    @Test("Google sign-in is offered only when the client ID and its URL scheme are both set up")
    func googleSetup() {
        let clientID = "1234-abcd.apps.googleusercontent.com"
        #expect(FirebaseSession.googleSetup(clientID: clientID, registeredScheme: "com.googleusercontent.apps.1234-abcd") == .ready(clientID: clientID))
        guard case let .unavailable(missingScheme) = FirebaseSession.googleSetup(clientID: clientID, registeredScheme: nil) else {
            Issue.record("expected unavailable"); return
        }
        #expect(missingScheme.contains("GOOGLE_REVERSED_CLIENT_ID = com.googleusercontent.apps.1234-abcd"))
        guard case let .unavailable(noClient) = FirebaseSession.googleSetup(clientID: nil, registeredScheme: nil) else {
            Issue.record("expected unavailable"); return
        }
        #expect(noClient.contains("enable Google in Firebase Authentication"))
        #expect(FirebaseSession.googleSetup(clientID: clientID, registeredScheme: "com.googleusercontent.apps.other") != .ready(clientID: clientID))
    }

    @Test("Email errors are actionable and never reveal whether an account exists")
    func emailErrors() {
        func message(_ code: AuthErrorCode) -> String {
            FirebaseSession.describeEmail(NSError(domain: AuthErrorDomain, code: code.rawValue)).localizedDescription
        }
        #expect(message(.wrongPassword) == message(.userNotFound))
        #expect(message(.invalidCredential) == message(.userNotFound))
        #expect(message(.wrongPassword).contains("Email or password is incorrect"))
        #expect(message(.emailAlreadyInUse).contains("already exists"))
        #expect(message(.weakPassword).contains("\(FirebaseSession.minimumPasswordLength) characters"))
        #expect(message(.operationNotAllowed).contains("Email/Password"))
        #expect(FirebaseSession.describeEmail(NSError(domain: AuthErrorDomain, code: AuthErrorCode.networkError.rawValue)) == .offline)
    }

    @Test("Only email accounts wait for address confirmation; labels name the sign-in method")
    func accountState() {
        let unverified = FirebaseSession.Account(method: .email, email: "driver@example.com", emailVerified: false)
        #expect(unverified.needsEmailVerification)
        #expect(unverified.label == "driver@example.com")
        #expect(!FirebaseSession.Account(method: .email, email: "driver@example.com", emailVerified: true).needsEmailVerification)
        #expect(!FirebaseSession.Account(method: .google, email: "driver@example.com", emailVerified: false).needsEmailVerification)
        #expect(FirebaseSession.Account(method: .google, email: "driver@example.com", emailVerified: true).label == "Google · driver@example.com")
        #expect(FirebaseSession.Account(method: .emulator, email: nil, emailVerified: false).label == "Emulator test account")
    }

    @Test("This build has the Apple Developer Program features off (free personal team)")
    func appleProgramOff() {
        #expect(!FirebaseSession.appleDeveloperProgram)
    }
}
