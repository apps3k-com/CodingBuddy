//
//  AgentDoctorGuidance.swift
//  CodingBuddy
//

import Foundation

/// Deterministic explainable guidance for every Agent Doctor diagnostic code.
nonisolated enum AgentDoctorGuidance {
    /// Opens the CodingBuddy destination that owns the finding.
    static let openDestinationActionID = "agent-doctor.action.open-destination"
    /// Opens an existing local source file in the configured external editor.
    static let openSourceActionID = "agent-doctor.action.open-source"
    /// Describes the permission repair that CodingBuddy cannot currently perform.
    static let restrictPermissionsActionID = "agent-doctor.action.restrict-permissions"

    /// Maps model codes, never localized diagnostic prose, to stable guidance.
    static func guidance(for diagnostic: AgentDiagnostic, canOpenSource: Bool) -> Guidance {
        let evidence = technicalEvidence(for: diagnostic)

        switch diagnostic.code {
        case .missingDirectory:
            return Guidance(
                id: guidanceID(for: diagnostic),
                explanation: String(
                    localized: "Agent Doctor guidance missing directory explanation",
                    defaultValue: "The expected local configuration directory does not exist."
                ),
                relevance: String(
                    localized: "Agent Doctor guidance missing directory relevance",
                    defaultValue:
                        "Agent Doctor uses this directory to inspect the tool's local setup. Its absence often means the tool has not been set up or used for this macOS account."
                ),
                consequence: String(
                    localized: "Agent Doctor guidance missing directory consequence",
                    defaultValue:
                        "Nothing is affected if you do not use the tool. If you do, configuration-dependent features may remain unavailable until the tool creates its files."
                ),
                recommendedAction: openToolAction(
                    expectedResult: String(
                        localized: "Agent Doctor guidance missing directory open tool result",
                        defaultValue:
                            "The owning configuration area opens. The tool may still need to be launched or set up before the directory appears."
                    )
                ),
                alternatives: optionalSourceAction(canOpenSource: canOpenSource),
                technicalEvidence: evidence,
                glossaryTerms: []
            )

        case .missingZshStartupFiles:
            return Guidance(
                id: guidanceID(for: diagnostic),
                explanation: String(
                    localized: "Agent Doctor guidance missing zsh startup files explanation",
                    defaultValue:
                        "None of the zsh startup files managed by CodingBuddy exists in this home directory."
                ),
                relevance: String(
                    localized: "Agent Doctor guidance missing zsh startup files relevance",
                    defaultValue:
                        "CodingBuddy reads these files to manage environment variables used by terminal sessions and developer tools."
                ),
                consequence: String(
                    localized: "Agent Doctor guidance missing zsh startup files consequence",
                    defaultValue:
                        "New terminal sessions may not receive the environment variables your tools expect."
                ),
                recommendedAction: openVariablesAction(),
                // The scanner reports the home directory here because no startup file exists.
                // A directory is not a useful source-file alternative for this finding.
                alternatives: [],
                technicalEvidence: evidence,
                glossaryTerms: []
            )

        case .invalidConfigFile:
            let sourceAction = openSourceAction(canOpenSource: canOpenSource)
            let toolAction = openToolAction(
                expectedResult: String(
                    localized: "Agent Doctor guidance invalid config file open tool result",
                    defaultValue:
                        "The owning configuration area opens so you can compare the file with the tool's current setup."
                )
            )
            return Guidance(
                id: guidanceID(for: diagnostic),
                explanation: String(
                    localized: "Agent Doctor guidance invalid config file explanation",
                    defaultValue: "A configuration file exists, but its contents do not form valid JSON."
                ),
                relevance: String(
                    localized: "Agent Doctor guidance invalid config file relevance",
                    defaultValue: "The owning tool may be unable to read settings from a file it cannot parse."
                ),
                consequence: String(
                    localized: "Agent Doctor guidance invalid config file consequence",
                    defaultValue:
                        "Settings or connections declared in the file may be ignored until its JSON syntax is corrected."
                ),
                recommendedAction: canOpenSource ? sourceAction : toolAction,
                alternatives: canOpenSource ? [toolAction] : [sourceAction],
                technicalEvidence: evidence,
                glossaryTerms: []
            )

        case .missingReferencedEnvVar:
            return Guidance(
                id: guidanceID(for: diagnostic),
                explanation: String(
                    localized: "Agent Doctor guidance missing referenced env var explanation",
                    defaultValue:
                        "The tool configuration refers to an environment variable that CodingBuddy cannot find in the matching environment file."
                ),
                relevance: String(
                    localized: "Agent Doctor guidance missing referenced env var relevance",
                    defaultValue:
                        "MCP configurations commonly use environment variables to supply credentials or settings without embedding their values in configuration."
                ),
                consequence: String(
                    localized: "Agent Doctor guidance missing referenced env var consequence",
                    defaultValue:
                        "The related MCP connection may fail because the tool cannot resolve the referenced variable."
                ),
                recommendedAction: openToolAction(
                    expectedResult: String(
                        localized: "Agent Doctor guidance missing referenced env var open tool result",
                        defaultValue:
                            "The owning tool's environment configuration opens so you can define the missing variable through its existing workflow."
                    )
                ),
                alternatives: [openSourceAction(canOpenSource: canOpenSource)],
                technicalEvidence: evidence,
                glossaryTerms: [.mcp]
            )

        case .unsafePermissions:
            return Guidance(
                id: guidanceID(for: diagnostic),
                explanation: String(
                    localized: "Agent Doctor guidance unsafe permissions explanation",
                    defaultValue:
                        "A credential-bearing file grants group or other users more access than Agent Doctor expects."
                ),
                relevance: String(
                    localized: "Agent Doctor guidance unsafe permissions relevance",
                    defaultValue:
                        "Broader file permissions can expose credentials to another account on the same Mac."
                ),
                consequence: String(
                    localized: "Agent Doctor guidance unsafe permissions consequence",
                    defaultValue:
                        "Another local account could read or alter credential material, depending on the current file mode."
                ),
                recommendedAction: restrictPermissionsAction(),
                alternatives: [openSourceAction(canOpenSource: canOpenSource)],
                technicalEvidence: evidence,
                glossaryTerms: []
            )

        case .expiredCredential:
            return Guidance(
                id: guidanceID(for: diagnostic),
                explanation: String(
                    localized: "Agent Doctor guidance expired credential explanation",
                    defaultValue:
                        "The cached OAuth access token appears to be past its recorded expiry time. An OAuth client may refresh it automatically, but Agent Doctor cannot confirm whether that refresh will succeed."
                ),
                relevance: String(
                    localized: "Agent Doctor guidance expired credential relevance",
                    defaultValue:
                        "An MCP server connection depends on a current OAuth login or a successful token refresh."
                ),
                consequence: String(
                    localized: "Agent Doctor guidance expired credential consequence",
                    defaultValue:
                        "The connection may keep working after an automatic refresh, ask you to sign in again, or fail until the login is renewed."
                ),
                recommendedAction: openMCPAuthAction(),
                alternatives: [openSourceAction(canOpenSource: canOpenSource)],
                technicalEvidence: evidence,
                glossaryTerms: [.mcp, .oauth]
            )

        case .incompleteCredential:
            return Guidance(
                id: guidanceID(for: diagnostic),
                explanation: String(
                    localized: "Agent Doctor guidance incomplete credential explanation",
                    defaultValue:
                        "An OAuth cache entry exists without the tokens file needed for a complete login. Agent Doctor cannot tell whether login was interrupted, canceled, or never completed."
                ),
                relevance: String(
                    localized: "Agent Doctor guidance incomplete credential relevance",
                    defaultValue:
                        "The MCP client needs a complete OAuth cache entry before it can reuse that login."
                ),
                consequence: String(
                    localized: "Agent Doctor guidance incomplete credential consequence",
                    defaultValue:
                        "The connection may ask you to sign in again or fail until a complete credential is created."
                ),
                recommendedAction: openMCPAuthAction(),
                alternatives: [openSourceAction(canOpenSource: canOpenSource)],
                technicalEvidence: evidence,
                glossaryTerms: [.mcp, .oauth]
            )

        case .credentialScanIncomplete:
            return Guidance(
                id: guidanceID(for: diagnostic),
                explanation: String(
                    localized: "Agent Doctor guidance incomplete credential scan explanation",
                    defaultValue:
                        "Agent Doctor deliberately omitted part of the MCP Auth cache because it could not inspect that input within its safety limits."
                ),
                relevance: String(
                    localized: "Agent Doctor guidance incomplete credential scan relevance",
                    defaultValue:
                        "A complete credential-cache scan is required before an empty or healthy result can be trusted."
                ),
                consequence: String(
                    localized: "Agent Doctor guidance incomplete credential scan consequence",
                    defaultValue:
                        "Additional expired, incomplete, or unsafe credential artifacts may exist outside the reported findings."
                ),
                recommendedAction: openMCPAuthAction(),
                alternatives: [],
                technicalEvidence: evidence,
                glossaryTerms: [.mcp, .oauth]
            )
        }
    }

    /// Keeps guidance identity tied to the selected diagnostic instance.
    private static func guidanceID(for diagnostic: AgentDiagnostic) -> String {
        "agent-doctor.guidance.\(diagnostic.id)"
    }

    /// Resolves the existing CodingBuddy destination for a guidance action.
    /// Credential diagnostics always belong to MCP Auth, even if malformed input names another tool.
    static func destinationTool(for diagnostic: AgentDiagnostic) -> AgentDiagnosticTool {
        switch diagnostic.code {
        case .expiredCredential, .incompleteCredential, .credentialScanIncomplete:
            .mcpAuth
        case .missingDirectory,
             .missingZshStartupFiles,
             .invalidConfigFile,
             .missingReferencedEnvVar,
             .unsafePermissions:
            diagnostic.tool
        }
    }

    /// Builds the existing read-only route to the diagnostic's owning tool.
    private static func openToolAction(expectedResult: String) -> RecommendedAction {
        RecommendedAction(
            id: openDestinationActionID,
            title: String(localized: "Agent Doctor guidance open tool action title", defaultValue: "Open tool"),
            expectedResult: expectedResult,
            effort: .low,
            safetyClass: .readOnly,
            availability: .available
        )
    }

    /// Builds the read-only route to CodingBuddy's environment-variable list.
    private static func openVariablesAction() -> RecommendedAction {
        RecommendedAction(
            id: openDestinationActionID,
            title: String(
                localized: "Agent Doctor guidance open variables action title",
                defaultValue: "Open variables"
            ),
            expectedResult: String(
                localized: "Agent Doctor guidance open variables action result",
                defaultValue:
                    "The environment variable list opens so you can create a variable through CodingBuddy's existing workflow."
            ),
            effort: .low,
            safetyClass: .readOnly,
            availability: .available
        )
    }

    /// Builds the read-only route to MCP Auth for credential inspection.
    private static func openMCPAuthAction() -> RecommendedAction {
        RecommendedAction(
            id: openDestinationActionID,
            title: String(localized: "Agent Doctor guidance open MCP Auth action title", defaultValue: "Open MCP Auth"),
            expectedResult: String(
                localized: "Agent Doctor guidance open MCP Auth action result",
                defaultValue:
                    "MCP Auth opens so you can inspect the entry and reset it only if the connection still fails. Opening it does not start a new login."
            ),
            effort: .low,
            safetyClass: .readOnly,
            availability: .available
        )
    }

    /// Builds a source-file action with an explicit unavailable reason when needed.
    private static func openSourceAction(canOpenSource: Bool) -> RecommendedAction {
        RecommendedAction(
            id: openSourceActionID,
            title: String(
                localized: "Agent Doctor guidance open source action title",
                defaultValue: "Open source"
            ),
            expectedResult: String(
                localized: "Agent Doctor guidance open source action result",
                defaultValue:
                    "The reported file opens in your configured external editor so you can inspect it."
            ),
            effort: .low,
            safetyClass: .readOnly,
            availability: canOpenSource
                ? .available
                : .unavailable(
                    reason: String(
                        localized: "Agent Doctor guidance source unavailable reason",
                        defaultValue:
                            "The reported source is not an existing local file, so CodingBuddy cannot open it."
                    )
                )
        )
    }

    /// Omits a secondary source action when no existing local file can be opened.
    private static func optionalSourceAction(canOpenSource: Bool) -> [RecommendedAction] {
        canOpenSource ? [openSourceAction(canOpenSource: true)] : []
    }

    /// Describes the desired permission repair without offering unsupported mutation.
    private static func restrictPermissionsAction() -> RecommendedAction {
        RecommendedAction(
            id: restrictPermissionsActionID,
            title: String(
                localized: "Agent Doctor guidance restrict permissions action title",
                defaultValue: "Restrict file permissions"
            ),
            expectedResult: String(
                localized: "Agent Doctor guidance restrict permissions action result",
                defaultValue:
                    "The credential file would be readable and writable only by your macOS user."
            ),
            effort: .low,
            safetyClass: .requiresConfirmation,
            availability: .unavailable(
                reason: String(
                    localized: "Agent Doctor guidance restrict permissions unavailable reason",
                    defaultValue:
                        "CodingBuddy cannot change file permissions. Open the source to inspect it and make this change outside the app."
                )
            )
        )
    }

    /// Builds evidence only from field shapes guaranteed by AgentDiagnostic.
    private static func technicalEvidence(for diagnostic: AgentDiagnostic) -> [TechnicalEvidence] {
        var evidence = [
            TechnicalEvidence(
                id: "agent-doctor.evidence.diagnostic-code",
                label: String(
                    localized: "Agent Doctor guidance evidence diagnostic code label",
                    defaultValue: "Diagnostic code"
                ),
                sanitizedValue: diagnostic.code.rawValue
            ),
            TechnicalEvidence(
                id: "agent-doctor.evidence.tool",
                label: String(localized: "Agent Doctor guidance evidence tool label", defaultValue: "Tool"),
                sanitizedValue: diagnostic.tool.displayName
            ),
        ]

        switch diagnostic.code {
        case .missingDirectory, .missingZshStartupFiles, .invalidConfigFile:
            appendLocalSourceEvidence(from: diagnostic.source, to: &evidence)

        case .missingReferencedEnvVar:
            appendLocalSourceEvidence(from: diagnostic.source, to: &evidence)
            if let subject = diagnostic.subject, isEnvironmentVariableName(subject) {
                evidence.append(
                    TechnicalEvidence(
                        id: "agent-doctor.evidence.referenced-variable",
                        label: String(
                            localized: "Agent Doctor guidance evidence referenced variable label",
                            defaultValue: "Referenced variable"
                        ),
                        sanitizedValue: subject
                    )
                )
            }

        case .unsafePermissions:
            appendLocalSourceEvidence(from: diagnostic.source, to: &evidence)
            if let subject = diagnostic.subject, isFileMode(subject) {
                evidence.append(
                    TechnicalEvidence(
                        id: "agent-doctor.evidence.file-mode",
                        label: String(
                            localized: "Agent Doctor guidance evidence file mode label",
                            defaultValue: "Reported file mode"
                        ),
                        sanitizedValue: subject
                    )
                )
            }

        case .expiredCredential, .incompleteCredential:
            if let subject = diagnostic.subject, isCredentialIdentifier(subject) {
                evidence.append(
                    TechnicalEvidence(
                        id: "agent-doctor.evidence.credential-entry",
                        label: String(
                            localized: "Agent Doctor guidance evidence credential entry label",
                            defaultValue: "Credential entry"
                        ),
                        sanitizedValue: subject
                    )
                )
            }
        case .credentialScanIncomplete:
            break
        }

        return evidence
    }

    /// Appends source evidence only after validating it as a local display-safe path.
    private static func appendLocalSourceEvidence(
        from source: String,
        to evidence: inout [TechnicalEvidence]
    ) {
        guard isLocalPath(source) else { return }
        evidence.append(
            TechnicalEvidence(
                id: "agent-doctor.evidence.source",
                label: String(localized: "Agent Doctor guidance evidence source label", defaultValue: "Source"),
                sanitizedValue: source
            )
        )
    }

    /// Rejects URLs and control-bearing values from local path evidence.
    private static func isLocalPath(_ value: String) -> Bool {
        value.hasPrefix("/")
            && !value.contains("://")
            && value.unicodeScalars.allSatisfy { scalar in
                scalar.value >= 0x20 && scalar.value != 0x7F
            }
    }

    /// Accepts only the portable ASCII shape used for environment-variable names.
    private static func isEnvironmentVariableName(_ value: String) -> Bool {
        guard let first = value.utf8.first, isASCIILetter(first) || first == 95 else { return false }
        return value.utf8.dropFirst().allSatisfy { byte in
            isASCIILetter(byte) || (48...57).contains(byte) || byte == 95
        }
    }

    /// Returns whether one UTF-8 byte is an ASCII alphabetic character.
    private static func isASCIILetter(_ byte: UInt8) -> Bool {
        (65...90).contains(byte) || (97...122).contains(byte)
    }

    /// Accepts only compact octal permission modes safe for evidence display.
    private static func isFileMode(_ value: String) -> Bool {
        (3...4).contains(value.count) && value.allSatisfy { character in
            guard let digit = character.wholeNumberValue else { return false }
            return (0...7).contains(digit)
        }
    }

    /// Accepts only bounded hexadecimal credential identifiers, never credential values.
    private static func isCredentialIdentifier(_ value: String) -> Bool {
        (8...32).contains(value.count) && value.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 48...57, 65...70, 97...102:
                true
            default:
                false
            }
        }
    }
}
