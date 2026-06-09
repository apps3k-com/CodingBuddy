//
//  SecretDetectorTests.swift
//  EnvVarBuddyTests
//

import Testing
@testable import EnvVarBuddy

struct SecretDetectorTests {

    @Test(arguments: [
        "GITHUB_TOKEN",
        "AWS_SECRET_ACCESS_KEY",
        "DATABASE_PASSWORD",
        "NPM_AUTH",
        "MY_APIKEY",
        "API_KEY",
        "STRIPE_SK_PWD",
        "OPENAI_API_KEY",
        "SSH_PRIVATE_CERT",
        "SENTRY_DSN",
        "npm_token",
    ])
    func sensitiveNamesAreDetected(name: String) {
        #expect(SecretDetector.isSensitive(name: name))
    }

    @Test(arguments: [
        "PATH",
        "EDITOR",
        "LANG",
        "HOMEBREW_PREFIX",
        "XDG_CONFIG_HOME",
        "JAVA_HOME",
        "TERM",
        "KEYBOARD_LAYOUT",
    ])
    func ordinaryNamesAreNotDetected(name: String) {
        #expect(!SecretDetector.isSensitive(name: name))
    }
}
