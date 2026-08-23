import Foundation
import Testing
@testable import TacitCore

@Test func validateURLAcceptsDeepLinkScheme() {
    #expect(ActionValidation.validateURL("superwhisper://record"))
}

@Test func validateURLAcceptsHTTPS() {
    #expect(ActionValidation.validateURL("https://example.com"))
}

@Test func validateURLAcceptsAnyRegisteredScheme() {
    #expect(ActionValidation.validateURL("raycast://confetti"))
}

@Test func validateURLRejectsSchemelessString() {
    #expect(!ActionValidation.validateURL("hello"))
}

@Test func validateURLRejectsSchemelessDomain() {
    #expect(!ActionValidation.validateURL("example.com"))
}

@Test func validateURLRejectsEmptyString() {
    #expect(!ActionValidation.validateURL(""))
}
