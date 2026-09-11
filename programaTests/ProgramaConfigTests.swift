import XCTest

#if canImport(Programa_DEV)
@testable import Programa_DEV
#elseif canImport(Programa)
@testable import Programa
#endif

// MARK: - JSON Decoding

final class ProgramaConfigDecodingTests: XCTestCase {

    private func decode(_ json: String) throws -> ProgramaConfigFile {
        let data = json.data(using: .utf8)!
        return try JSONDecoder().decode(ProgramaConfigFile.self, from: data)
    }

    // MARK: Simple commands

    func testDecodeSimpleCommand() throws {
        let json = """
        {
          "commands": [{
            "name": "Run tests",
            "command": "npm test"
          }]
        }
        """
        let config = try decode(json)
        XCTAssertEqual(config.commands.count, 1)
        XCTAssertEqual(config.commands[0].name, "Run tests")
        XCTAssertEqual(config.commands[0].command, "npm test")
        XCTAssertNil(config.commands[0].workspace)
    }

    func testDecodeSimpleCommandWithAllFields() throws {
        let json = """
        {
          "commands": [{
            "name": "Deploy",
            "description": "Deploy to production",
            "keywords": ["ship", "release"],
            "command": "make deploy",
            "confirm": true
          }]
        }
        """
        let config = try decode(json)
        let cmd = config.commands[0]
        XCTAssertEqual(cmd.name, "Deploy")
        XCTAssertEqual(cmd.description, "Deploy to production")
        XCTAssertEqual(cmd.keywords, ["ship", "release"])
        XCTAssertEqual(cmd.command, "make deploy")
        XCTAssertEqual(cmd.confirm, true)
    }

    func testDecodeMultipleCommands() throws {
        let json = """
        {
          "commands": [
            { "name": "Build", "command": "make build" },
            { "name": "Test", "command": "make test" },
            { "name": "Lint", "command": "make lint" }
          ]
        }
        """
        let config = try decode(json)
        XCTAssertEqual(config.commands.count, 3)
        XCTAssertEqual(config.commands.map(\.name), ["Build", "Test", "Lint"])
    }

    func testDecodeEmptyCommandsArray() throws {
        let json = """
        { "commands": [] }
        """
        let config = try decode(json)
        XCTAssertTrue(config.commands.isEmpty)
    }

    // MARK: Workspace commands

    func testDecodeWorkspaceCommand() throws {
        let json = """
        {
          "commands": [{
            "name": "Dev env",
            "workspace": {
              "name": "Development",
              "cwd": "~/projects/app",
              "color": "#FF5733"
            }
          }]
        }
        """
        let config = try decode(json)
        let ws = config.commands[0].workspace
        XCTAssertNotNil(ws)
        XCTAssertEqual(ws?.name, "Development")
        XCTAssertEqual(ws?.cwd, "~/projects/app")
        XCTAssertEqual(ws?.color, "#FF5733")
    }

    func testDecodeRestartBehaviors() throws {
        for behavior in ["recreate", "ignore", "confirm"] {
            let json = """
            {
              "commands": [{
                "name": "test",
                "restart": "\(behavior)",
                "workspace": { "name": "ws" }
              }]
            }
            """
            let config = try decode(json)
            XCTAssertEqual(config.commands[0].restart?.rawValue, behavior)
        }
    }

    // MARK: Layout tree

    func testDecodePaneNode() throws {
        let json = """
        {
          "commands": [{
            "name": "layout",
            "workspace": {
              "layout": {
                "pane": {
                  "surfaces": [
                    { "type": "terminal", "name": "shell" }
                  ]
                }
              }
            }
          }]
        }
        """
        let config = try decode(json)
        let layout = config.commands[0].workspace!.layout!
        if case .pane(let pane) = layout {
            XCTAssertEqual(pane.surfaces.count, 1)
            XCTAssertEqual(pane.surfaces[0].type, .terminal)
            XCTAssertEqual(pane.surfaces[0].name, "shell")
        } else {
            XCTFail("Expected pane node")
        }
    }

    func testDecodeSplitNode() throws {
        let json = """
        {
          "commands": [{
            "name": "layout",
            "workspace": {
              "layout": {
                "direction": "horizontal",
                "split": 0.3,
                "children": [
                  { "pane": { "surfaces": [{ "type": "terminal" }] } },
                  { "pane": { "surfaces": [{ "type": "terminal" }] } }
                ]
              }
            }
          }]
        }
        """
        let config = try decode(json)
        let layout = config.commands[0].workspace!.layout!
        if case .split(let split) = layout {
            XCTAssertEqual(split.direction, .horizontal)
            XCTAssertEqual(split.split, 0.3)
            XCTAssertEqual(split.children.count, 2)
        } else {
            XCTFail("Expected split node")
        }
    }

    func testDecodeNestedSplits() throws {
        let json = """
        {
          "commands": [{
            "name": "nested",
            "workspace": {
              "layout": {
                "direction": "horizontal",
                "children": [
                  { "pane": { "surfaces": [{ "type": "terminal" }] } },
                  {
                    "direction": "vertical",
                    "children": [
                      { "pane": { "surfaces": [{ "type": "terminal" }] } },
                      { "pane": { "surfaces": [{ "type": "browser", "url": "http://localhost:3000" }] } }
                    ]
                  }
                ]
              }
            }
          }]
        }
        """
        let config = try decode(json)
        let layout = config.commands[0].workspace!.layout!
        if case .split(let outer) = layout {
            XCTAssertEqual(outer.direction, .horizontal)
            if case .split(let inner) = outer.children[1] {
                XCTAssertEqual(inner.direction, .vertical)
                if case .pane(let browserPane) = inner.children[1] {
                    XCTAssertEqual(browserPane.surfaces[0].type, .browser)
                    XCTAssertEqual(browserPane.surfaces[0].url, "http://localhost:3000")
                } else {
                    XCTFail("Expected pane node for inner second child")
                }
            } else {
                XCTFail("Expected split node for outer second child")
            }
        } else {
            XCTFail("Expected split node")
        }
    }

    // MARK: Surface definitions

    func testDecodeTerminalSurfaceAllFields() throws {
        let json = """
        {
          "commands": [{
            "name": "test",
            "workspace": {
              "layout": {
                "pane": {
                  "surfaces": [{
                    "type": "terminal",
                    "name": "server",
                    "command": "npm start",
                    "cwd": "./backend",
                    "env": { "NODE_ENV": "development", "PORT": "3000" },
                    "focus": true
                  }]
                }
              }
            }
          }]
        }
        """
        let config = try decode(json)
        let surface = config.commands[0].workspace!.layout!
        if case .pane(let pane) = surface {
            let s = pane.surfaces[0]
            XCTAssertEqual(s.type, .terminal)
            XCTAssertEqual(s.name, "server")
            XCTAssertEqual(s.command, "npm start")
            XCTAssertEqual(s.cwd, "./backend")
            XCTAssertEqual(s.env, ["NODE_ENV": "development", "PORT": "3000"])
            XCTAssertEqual(s.focus, true)
            XCTAssertNil(s.url)
        } else {
            XCTFail("Expected pane node")
        }
    }

    func testDecodeBrowserSurface() throws {
        let json = """
        {
          "commands": [{
            "name": "test",
            "workspace": {
              "layout": {
                "pane": {
                  "surfaces": [{
                    "type": "browser",
                    "name": "Preview",
                    "url": "http://localhost:8080"
                  }]
                }
              }
            }
          }]
        }
        """
        let config = try decode(json)
        if case .pane(let pane) = config.commands[0].workspace!.layout! {
            let s = pane.surfaces[0]
            XCTAssertEqual(s.type, .browser)
            XCTAssertEqual(s.url, "http://localhost:8080")
        } else {
            XCTFail("Expected pane node")
        }
    }

    func testDecodeMultipleSurfacesInPane() throws {
        let json = """
        {
          "commands": [{
            "name": "test",
            "workspace": {
              "layout": {
                "pane": {
                  "surfaces": [
                    { "type": "terminal", "name": "shell1" },
                    { "type": "terminal", "name": "shell2" },
                    { "type": "browser", "name": "web" }
                  ]
                }
              }
            }
          }]
        }
        """
        let config = try decode(json)
        if case .pane(let pane) = config.commands[0].workspace!.layout! {
            XCTAssertEqual(pane.surfaces.count, 3)
            XCTAssertEqual(pane.surfaces.map(\.name), ["shell1", "shell2", "web"])
        } else {
            XCTFail("Expected pane node")
        }
    }

    // MARK: Decoding errors

    func testDecodeInvalidLayoutNodeThrows() {
        let json = """
        {
          "commands": [{
            "name": "bad",
            "workspace": {
              "layout": { "invalid": true }
            }
          }]
        }
        """
        XCTAssertThrowsError(try decode(json))
    }

    func testDecodeMissingCommandsKeyThrows() {
        let json = """
        { "notCommands": [] }
        """
        XCTAssertThrowsError(try decode(json))
    }

    func testDecodeInvalidSurfaceTypeThrows() {
        let json = """
        {
          "commands": [{
            "name": "test",
            "workspace": {
              "layout": {
                "pane": {
                  "surfaces": [{ "type": "invalidType" }]
                }
              }
            }
          }]
        }
        """
        XCTAssertThrowsError(try decode(json))
    }

    // MARK: Command validation

    func testDecodeCommandWithNeitherWorkspaceNorCommandThrows() {
        let json = """
        {
          "commands": [{
            "name": "empty"
          }]
        }
        """
        XCTAssertThrowsError(try decode(json))
    }

    func testDecodeCommandWithBothWorkspaceAndCommandThrows() {
        let json = """
        {
          "commands": [{
            "name": "hybrid",
            "command": "echo hi",
            "workspace": { "name": "ws" }
          }]
        }
        """
        XCTAssertThrowsError(try decode(json))
    }

    // MARK: Layout validation

    func testDecodeLayoutNodeWithBothPaneAndDirectionThrows() {
        let json = """
        {
          "commands": [{
            "name": "ambiguous",
            "workspace": {
              "layout": {
                "pane": { "surfaces": [{ "type": "terminal" }] },
                "direction": "horizontal",
                "children": [
                  { "pane": { "surfaces": [{ "type": "terminal" }] } },
                  { "pane": { "surfaces": [{ "type": "terminal" }] } }
                ]
              }
            }
          }]
        }
        """
        XCTAssertThrowsError(try decode(json))
    }

    func testDecodeSplitWithWrongChildrenCountThrows() {
        let json = """
        {
          "commands": [{
            "name": "bad-split",
            "workspace": {
              "layout": {
                "direction": "horizontal",
                "children": [
                  { "pane": { "surfaces": [{ "type": "terminal" }] } }
                ]
              }
            }
          }]
        }
        """
        XCTAssertThrowsError(try decode(json))
    }

    func testDecodeSplitWithThreeChildrenThrows() {
        let json = """
        {
          "commands": [{
            "name": "bad-split",
            "workspace": {
              "layout": {
                "direction": "vertical",
                "children": [
                  { "pane": { "surfaces": [{ "type": "terminal" }] } },
                  { "pane": { "surfaces": [{ "type": "terminal" }] } },
                  { "pane": { "surfaces": [{ "type": "terminal" }] } }
                ]
              }
            }
          }]
        }
        """
        XCTAssertThrowsError(try decode(json))
    }

    func testDecodePaneWithEmptySurfacesThrows() {
        let json = """
        {
          "commands": [{
            "name": "empty-pane",
            "workspace": {
              "layout": {
                "pane": { "surfaces": [] }
              }
            }
          }]
        }
        """
        XCTAssertThrowsError(try decode(json))
    }

    func testDecodeBlankNameThrows() {
        let json = """
        {
          "commands": [{
            "name": "",
            "command": "echo hi"
          }]
        }
        """
        XCTAssertThrowsError(try decode(json))
    }

    func testDecodeWhitespaceOnlyNameThrows() {
        let json = """
        {
          "commands": [{
            "name": "   ",
            "command": "echo hi"
          }]
        }
        """
        XCTAssertThrowsError(try decode(json))
    }

    func testDecodeBlankCommandThrows() {
        let json = """
        {
          "commands": [{
            "name": "test",
            "command": ""
          }]
        }
        """
        XCTAssertThrowsError(try decode(json))
    }

    func testDecodeWhitespaceOnlyCommandThrows() {
        let json = """
        {
          "commands": [{
            "name": "test",
            "command": "   "
          }]
        }
        """
        XCTAssertThrowsError(try decode(json))
    }

    // MARK: Recipes

    func testDecodeSimpleRecipe() throws {
        let json = """
        {
          "commands": [],
          "recipes": [{
            "name": "Fix a bug",
            "description": "Ask the agent to fix a bug in a file",
            "keywords": ["bug", "fix"],
            "prompt": "Please fix the bug in {{file}}: {{description}}",
            "parameters": [
              { "name": "file", "prompt": "File path" },
              { "name": "description", "prompt": "What's wrong", "default": "it crashes" }
            ]
          }]
        }
        """
        let config = try decode(json)
        XCTAssertEqual(config.recipes?.count, 1)
        let recipe = try XCTUnwrap(config.recipes?.first)
        XCTAssertEqual(recipe.name, "Fix a bug")
        XCTAssertEqual(recipe.description, "Ask the agent to fix a bug in a file")
        XCTAssertEqual(recipe.keywords, ["bug", "fix"])
        XCTAssertEqual(recipe.prompt, "Please fix the bug in {{file}}: {{description}}")
        XCTAssertEqual(recipe.parameters?.count, 2)
        XCTAssertEqual(recipe.parameters?[0].name, "file")
        XCTAssertEqual(recipe.parameters?[0].prompt, "File path")
        XCTAssertNil(recipe.parameters?[0].default)
        XCTAssertEqual(recipe.parameters?[1].default, "it crashes")
    }

    func testDecodeMissingRecipesKeyStillDecodes() throws {
        let json = """
        { "commands": [{ "name": "Build", "command": "make build" }] }
        """
        let config = try decode(json)
        XCTAssertNil(config.recipes)
    }

    func testDecodeRecipeWhitespaceOnlyNameThrows() {
        let json = """
        {
          "commands": [],
          "recipes": [{ "name": "   ", "prompt": "do something" }]
        }
        """
        XCTAssertThrowsError(try decode(json))
    }

    func testDecodeRecipeWhitespaceOnlyPromptThrows() {
        let json = """
        {
          "commands": [],
          "recipes": [{ "name": "test", "prompt": "   " }]
        }
        """
        XCTAssertThrowsError(try decode(json))
    }

    func testDecodeCommandWithParameters() throws {
        let json = """
        {
          "commands": [{
            "name": "Checkout branch",
            "command": "git checkout {{branch}}",
            "parameters": [{ "name": "branch", "prompt": "Branch name", "default": "main" }]
          }]
        }
        """
        let config = try decode(json)
        let cmd = config.commands[0]
        XCTAssertEqual(cmd.parameters?.count, 1)
        XCTAssertEqual(cmd.parameters?[0].name, "branch")
        XCTAssertEqual(cmd.parameters?[0].default, "main")
    }
}

// MARK: - JSONC (comments + trailing commas) config parsing
//
// Regression coverage for a real user pain point: a project's programa.json (ported from
// ~/.config/cmux/cmux.json) failed to parse with "Unexpected character '/' at line 5 col 4"
// because plain JSONDecoder rejects `//`/`/* */` comments and trailing commas. These tests
// exercise the same JSONCParser.preprocess -> JSONDecoder pipeline ProgramaConfigStore uses
// at runtime, not just the parser in isolation.
final class ProgramaConfigJSONCDecodingTests: XCTestCase {

    /// Mirrors what `ProgramaConfigStore.parseConfig(at:)` does at runtime: run the raw
    /// file text through `JSONCParser.preprocess` before handing it to `JSONDecoder`.
    private func decodeJSONC(_ jsonc: String) throws -> ProgramaConfigFile {
        let data = jsonc.data(using: .utf8)!
        let sanitized = try JSONCParser.preprocess(data: data)
        return try JSONDecoder().decode(ProgramaConfigFile.self, from: sanitized)
    }

    func testDecodeWithLineComments() throws {
        let jsonc = """
        {
          // top-level config for this project
          "commands": [{
            "name": "Run tests", // inline comment after a value
            "command": "npm test"
          }]
        }
        """
        let config = try decodeJSONC(jsonc)
        XCTAssertEqual(config.commands.count, 1)
        XCTAssertEqual(config.commands[0].name, "Run tests")
        XCTAssertEqual(config.commands[0].command, "npm test")
    }

    func testDecodeWithBlockComments() throws {
        let jsonc = """
        {
          /* This project's dev commands.
             Multi-line block comment. */
          "commands": [{
            "name": "Deploy" /* inline block comment */,
            "command": "make deploy"
          }]
        }
        """
        let config = try decodeJSONC(jsonc)
        XCTAssertEqual(config.commands[0].name, "Deploy")
        XCTAssertEqual(config.commands[0].command, "make deploy")
    }

    func testDecodeWithTrailingCommaInArray() throws {
        let jsonc = """
        {
          "commands": [
            { "name": "Build", "command": "make build" },
            { "name": "Test", "command": "make test" },
          ]
        }
        """
        let config = try decodeJSONC(jsonc)
        XCTAssertEqual(config.commands.map(\.name), ["Build", "Test"])
    }

    func testDecodeWithTrailingCommaInObject() throws {
        let jsonc = """
        {
          "commands": [{
            "name": "Deploy",
            "command": "make deploy",
          }],
        }
        """
        let config = try decodeJSONC(jsonc)
        XCTAssertEqual(config.commands[0].name, "Deploy")
        XCTAssertEqual(config.commands[0].command, "make deploy")
    }

    func testDecodeWithMixedCommentsAndTrailingCommas() throws {
        // Same shape as the config that motivated this port: comments describing each
        // command, plus trailing commas left over from copy-pasting entries.
        let jsonc = """
        {
          "commands": [
            {
              // Runs the full test suite
              "name": "Test",
              "command": "npm test",
            },
            {
              /* Starts the dev server on the default port */
              "name": "Dev",
              "workspace": {
                "name": "Dev",
                "cwd": "~/projects/app",
              },
            },
          ],
        }
        """
        let config = try decodeJSONC(jsonc)
        XCTAssertEqual(config.commands.map(\.name), ["Test", "Dev"])
        XCTAssertEqual(config.commands[0].command, "npm test")
        XCTAssertEqual(config.commands[1].workspace?.cwd, "~/projects/app")
    }

    func testDecodeIgnoresCommentLikeSequencesInsideStrings() throws {
        // A command string containing "//" or "/*" must not be treated as a comment.
        let jsonc = """
        {
          "commands": [{
            "name": "URL",
            "command": "curl https://example.com/*.json"
          }]
        }
        """
        let config = try decodeJSONC(jsonc)
        XCTAssertEqual(config.commands[0].command, "curl https://example.com/*.json")
    }

    func testDecodeIgnoresTrailingCommaLikeSequenceInsideStrings() throws {
        let jsonc = """
        {
          "commands": [{
            "name": "test",
            "command": "echo 'a, b,'"
          }]
        }
        """
        let config = try decodeJSONC(jsonc)
        XCTAssertEqual(config.commands[0].command, "echo 'a, b,'")
    }

    func testDecodeStripsUTF8BOM() throws {
        let jsonc = "\u{feff}{ \"commands\": [{ \"name\": \"Build\", \"command\": \"make\" }] }"
        let data = jsonc.data(using: .utf8)!
        let sanitized = try JSONCParser.preprocess(data: data)
        let config = try JSONDecoder().decode(ProgramaConfigFile.self, from: sanitized)
        XCTAssertEqual(config.commands[0].name, "Build")
    }

    func testDecodePlainJSONWithoutCommentsStillWorks() throws {
        // Strict JSON (no comments, no trailing commas) must keep working unmodified.
        let jsonc = """
        { "commands": [{ "name": "Build", "command": "make build" }] }
        """
        let config = try decodeJSONC(jsonc)
        XCTAssertEqual(config.commands[0].name, "Build")
    }

    // MARK: Error cases

    func testUnterminatedBlockCommentThrows() {
        let jsonc = "{\n/* missing close\n\"commands\": []\n}"
        let data = jsonc.data(using: .utf8)!
        XCTAssertThrowsError(try JSONCParser.preprocess(data: data)) { error in
            XCTAssertEqual((error as? LocalizedError)?.errorDescription, "unterminated block comment")
        }
    }

    func testCommentOnlyContentStillFailsJSONDecodingAfterPreprocessing() {
        // JSONCParser only strips comments/trailing commas; it does not make invalid JSON
        // valid. A comments-only file has nothing left to decode as an object.
        let jsonc = "// just a comment, no actual config\n"
        XCTAssertThrowsError(try decodeJSONC(jsonc))
    }

    func testMalformedJSONAfterCommentStrippingStillThrows() {
        let jsonc = """
        {
          // this command is missing its closing brace
          "commands": [{ "name": "Broken", "command": "echo hi" }
        """
        XCTAssertThrowsError(try decodeJSONC(jsonc))
    }
}

// MARK: - Command identity

final class ProgramaCommandIdentityTests: XCTestCase {

    func testCommandIdIsDeterministic() {
        let cmd = ProgramaCommandDefinition(name: "Run tests", command: "test")
        XCTAssertEqual(cmd.id, "cmux.config.command.Run%20tests")
    }

    func testCommandIdEncodesSpecialCharacters() {
        let cmd = ProgramaCommandDefinition(name: "build & deploy", command: "make")
        XCTAssertTrue(cmd.id.hasPrefix("cmux.config.command."))
        XCTAssertFalse(cmd.id.contains("&"))
        XCTAssertFalse(cmd.id.contains(" "))
    }

    func testCommandIdIsUniqueForDifferentNames() {
        let cmd1 = ProgramaCommandDefinition(name: "build", command: "make build")
        let cmd2 = ProgramaCommandDefinition(name: "test", command: "make test")
        XCTAssertNotEqual(cmd1.id, cmd2.id)
    }

    func testCommandIdDoesNotCollideWithBuiltinPrefix() {
        let cmd = ProgramaCommandDefinition(name: "palette.newWorkspace", command: "echo")
        XCTAssertTrue(cmd.id.hasPrefix("cmux.config.command."))
        XCTAssertNotEqual(cmd.id, "palette.newWorkspace")
    }
}

// MARK: - Split clamping

final class ProgramaSplitDefinitionTests: XCTestCase {

    func testClampedSplitPositionDefaultsToHalf() {
        let split = ProgramaSplitDefinition(direction: .horizontal, split: nil, children: [])
        XCTAssertEqual(split.clampedSplitPosition, 0.5)
    }

    func testClampedSplitPositionPassesThroughValidValue() {
        let split = ProgramaSplitDefinition(direction: .vertical, split: 0.3, children: [])
        XCTAssertEqual(split.clampedSplitPosition, 0.3, accuracy: 0.001)
    }

    func testClampedSplitPositionClampsLow() {
        let split = ProgramaSplitDefinition(direction: .horizontal, split: 0.01, children: [])
        XCTAssertEqual(split.clampedSplitPosition, 0.1, accuracy: 0.001)
    }

    func testClampedSplitPositionClampsHigh() {
        let split = ProgramaSplitDefinition(direction: .horizontal, split: 0.99, children: [])
        XCTAssertEqual(split.clampedSplitPosition, 0.9, accuracy: 0.001)
    }

    func testClampedSplitPositionClampsNegative() {
        let split = ProgramaSplitDefinition(direction: .horizontal, split: -1.0, children: [])
        XCTAssertEqual(split.clampedSplitPosition, 0.1, accuracy: 0.001)
    }

    func testClampedSplitPositionClampsAboveOne() {
        let split = ProgramaSplitDefinition(direction: .horizontal, split: 2.0, children: [])
        XCTAssertEqual(split.clampedSplitPosition, 0.9, accuracy: 0.001)
    }

    func testSplitOrientationHorizontal() {
        let split = ProgramaSplitDefinition(direction: .horizontal, split: nil, children: [])
        XCTAssertEqual(split.splitOrientation, .horizontal)
    }

    func testSplitOrientationVertical() {
        let split = ProgramaSplitDefinition(direction: .vertical, split: nil, children: [])
        XCTAssertEqual(split.splitOrientation, .vertical)
    }
}

// MARK: - CWD resolution

@MainActor
final class ProgramaConfigCwdResolutionTests: XCTestCase {

    private let baseCwd = "/Users/test/project"

    func testNilCwdReturnsBase() {
        XCTAssertEqual(
            ProgramaConfigStore.resolveCwd(nil, relativeTo: baseCwd),
            baseCwd
        )
    }

    func testEmptyCwdReturnsBase() {
        XCTAssertEqual(
            ProgramaConfigStore.resolveCwd("", relativeTo: baseCwd),
            baseCwd
        )
    }

    func testDotCwdReturnsBase() {
        XCTAssertEqual(
            ProgramaConfigStore.resolveCwd(".", relativeTo: baseCwd),
            baseCwd
        )
    }

    func testAbsolutePathReturnedAsIs() {
        XCTAssertEqual(
            ProgramaConfigStore.resolveCwd("/tmp/other", relativeTo: baseCwd),
            "/tmp/other"
        )
    }

    func testRelativePathJoinedToBase() {
        XCTAssertEqual(
            ProgramaConfigStore.resolveCwd("backend/src", relativeTo: baseCwd),
            "/Users/test/project/backend/src"
        )
    }

    func testTildeExpandsToHome() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(
            ProgramaConfigStore.resolveCwd("~", relativeTo: baseCwd),
            home
        )
    }

    func testTildeSlashExpandsToHomePlusPath() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(
            ProgramaConfigStore.resolveCwd("~/Documents/work", relativeTo: baseCwd),
            (home as NSString).appendingPathComponent("Documents/work")
        )
    }

    func testSingleSubdirectory() {
        XCTAssertEqual(
            ProgramaConfigStore.resolveCwd("src", relativeTo: baseCwd),
            "/Users/test/project/src"
        )
    }
}

// MARK: - Layout encoding round-trip

final class ProgramaLayoutEncodingTests: XCTestCase {

    func testPaneNodeRoundTrips() throws {
        let original = ProgramaLayoutNode.pane(ProgramaPaneDefinition(surfaces: [
            ProgramaSurfaceDefinition(type: .terminal, name: "shell")
        ]))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ProgramaLayoutNode.self, from: data)

        if case .pane(let pane) = decoded {
            XCTAssertEqual(pane.surfaces.count, 1)
            XCTAssertEqual(pane.surfaces[0].name, "shell")
        } else {
            XCTFail("Expected pane node after round-trip")
        }
    }

    func testSplitNodeRoundTrips() throws {
        let original = ProgramaLayoutNode.split(ProgramaSplitDefinition(
            direction: .vertical,
            split: 0.7,
            children: [
                .pane(ProgramaPaneDefinition(surfaces: [ProgramaSurfaceDefinition(type: .terminal)])),
                .pane(ProgramaPaneDefinition(surfaces: [ProgramaSurfaceDefinition(type: .browser, url: "http://localhost")]))
            ]
        ))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ProgramaLayoutNode.self, from: data)

        if case .split(let split) = decoded {
            XCTAssertEqual(split.direction, .vertical)
            XCTAssertEqual(split.split, 0.7)
            XCTAssertEqual(split.children.count, 2)
        } else {
            XCTFail("Expected split node after round-trip")
        }
    }
}

/// A `programa.json` can arrive by cloning somebody else's repo, so the decision to run what it
/// contains has to belong to the app, not to the file. It did not always: the confirmation gate
/// ran only when the file itself set `confirm: true`, so any config could opt out of being
/// checked by leaving the key off, and `workspace`-type commands were never gated at all.
///
/// These pin the corrected truth table. The first case is the one that used to execute
/// arbitrary shell with no prompt at all.
@MainActor
final class ProgramaConfigTrustGateTests: XCTestCase {
    func testUntrustedDirectoryPromptsEvenWhenConfigDoesNotAskForIt() {
        XCTAssertTrue(
            ProgramaConfigExecutor.requiresConfirmation(confirmFlag: false, isTrusted: false),
            "A config from an untrusted directory must be confirmed even though it never set confirm: true"
        )
    }

    func testUntrustedDirectoryPromptsWhenConfigAsksForIt() {
        XCTAssertTrue(ProgramaConfigExecutor.requiresConfirmation(confirmFlag: true, isTrusted: false))
    }

    func testTrustedDirectoryRunsWithoutPrompting() {
        XCTAssertFalse(ProgramaConfigExecutor.requiresConfirmation(confirmFlag: false, isTrusted: true))
    }

    func testTrustedDirectoryStillHonoursExplicitConfirm() {
        XCTAssertTrue(
            ProgramaConfigExecutor.requiresConfirmation(confirmFlag: true, isTrusted: true),
            "confirm: true stays meaningful in a trusted folder as an author's ask-me-anyway marker"
        )
    }

    func testTrustIsTheOnlyThingThatCanSuppressAPrompt() {
        for confirmFlag in [true, false] {
            XCTAssertTrue(
                ProgramaConfigExecutor.requiresConfirmation(confirmFlag: confirmFlag, isTrusted: false),
                "No value of confirm may suppress the prompt for an untrusted directory"
            )
        }
    }
}

/// `confirmIfUntrusted` treats a nil `configSourcePath` as trusted, on the assumption that nil
/// only ever means the user's own global config -- `loadAll()` is expected to populate
/// `commandSourcePaths[command.id]` for every command it loads, local and global alike, so a
/// missing entry never actually reaches that code path today. Nothing in the type system
/// enforces that, though: a future refactor that drops one of the two assignments in `loadAll()`
/// would silently reopen the original hole where an untrusted command runs unconfirmed.
///
/// This pins the invariant directly against the real `loadAll()` path (JSONC parsing included),
/// with both a local and a global config file present, rather than against the trust-gate logic
/// in isolation.
@MainActor
final class ProgramaConfigSourceTrackingTests: XCTestCase {
    func testConfigRevisionChangesOnlyWhenEffectiveConfigOrOwnershipChanges() throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let firstURL = tempRoot.appendingPathComponent("first.json")
        let secondURL = tempRoot.appendingPathComponent("second.json")
        let initialConfig = #"{"commands":[{"name":"Build","command":"echo one"}]}"#
        try initialConfig.write(to: firstURL, atomically: true, encoding: .utf8)
        try initialConfig.write(to: secondURL, atomically: true, encoding: .utf8)

        let store = ProgramaConfigStore()
        store.localConfigPath = firstURL.path
        store.globalConfigPath = tempRoot.appendingPathComponent("missing.json").path
        store.loadAll()
        let initialRevision = store.configRevision

        store.loadAll()
        store.loadAll()
        XCTAssertEqual(
            store.configRevision,
            initialRevision,
            "Unchanged watcher reloads must not invalidate every command-palette observer"
        )

        try #"{"commands":[{"name":"Build","command":"echo two"}]}"#
            .write(to: firstURL, atomically: true, encoding: .utf8)
        store.loadAll()
        XCTAssertEqual(store.configRevision, initialRevision + 1, "A command change must invalidate config consumers")

        try #"{"commands":[{"name":"Build","command":"echo two"}]}"#
            .write(to: secondURL, atomically: true, encoding: .utf8)
        store.localConfigPath = secondURL.path
        store.loadAll()
        XCTAssertEqual(
            store.configRevision,
            initialRevision + 2,
            "Moving the effective command to another source must invalidate its trust ownership"
        )
        XCTAssertEqual(store.commandSourcePaths.values.first, secondURL.path)
    }

    func testEveryLoadedCommandHasATraceableSourcePath() throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let localDir = tempRoot.appendingPathComponent("local")
        let globalDir = tempRoot.appendingPathComponent("global")
        try fm.createDirectory(at: localDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: globalDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let localConfigURL = localDir.appendingPathComponent("programa.json")
        let globalConfigURL = globalDir.appendingPathComponent("programa.json")

        try #"""
        { "commands": [{ "name": "Local Command", "command": "echo local" }],
          "recipes": [{ "name": "Local Recipe", "prompt": "do the local thing" }] }
        """#
            .write(to: localConfigURL, atomically: true, encoding: .utf8)
        try #"""
        { "commands": [{ "name": "Global Command", "command": "echo global" }],
          "recipes": [{ "name": "Global Recipe", "prompt": "do the global thing" }] }
        """#
            .write(to: globalConfigURL, atomically: true, encoding: .utf8)

        let store = ProgramaConfigStore()
        store.localConfigPath = localConfigURL.path
        store.globalConfigPath = globalConfigURL.path
        store.loadAll()

        XCTAssertEqual(store.loadedCommands.map(\.name).sorted(), ["Global Command", "Local Command"])
        for command in store.loadedCommands {
            XCTAssertNotNil(
                store.commandSourcePaths[command.id],
                "Command '\(command.name)' has no recorded source path -- confirmIfUntrusted " +
                "treats a missing source path as the trusted global config, so this would make " +
                "the command run without confirmation regardless of which directory it came from."
            )
        }

        XCTAssertEqual(store.loadedRecipes.map(\.name).sorted(), ["Global Recipe", "Local Recipe"])
        for recipe in store.loadedRecipes {
            XCTAssertNotNil(
                store.recipeSourcePaths[recipe.id],
                "Recipe '\(recipe.name)' has no recorded source path -- confirmIfUntrusted " +
                "treats a missing source path as the trusted global config, so this would make " +
                "the recipe run without confirmation regardless of which directory it came from."
            )
        }
    }
}

/// The trust gate only buys anything if the dialog actually says what will happen. It did not
/// at first: the summary listed a surface's `command` and nothing else, so a surface carrying
/// only `env` contributed no line at all. Since `env` reaches the spawned shell unfiltered
/// (`Workspace+Layout.swift` passes it as `startupEnvironment`, and only Programa's own
/// `PROGRAMA_*` keys are protected), a config could set `ZDOTDIR` or `BASH_ENV` to a file in
/// its own repo and get code execution behind a dialog that read "Open workspace" and listed
/// nothing. These pin the disclosure.
@MainActor
final class ProgramaConfigConsentDisclosureTests: XCTestCase {
    private func decodeCommand(_ json: String) throws -> ProgramaCommandDefinition {
        let file = try JSONDecoder().decode(ProgramaConfigFile.self, from: Data(json.utf8))
        return try XCTUnwrap(file.commands.first)
    }

    /// The original bypass payload: no `command` anywhere, execution smuggled via ZDOTDIR.
    func testEnvOnlySurfaceIsDisclosed() throws {
        let command = try decodeCommand("""
        {"commands":[{"name":"Totally Normal Dev Setup","workspace":{"name":"dev",
        "layout":{"pane":{"surfaces":[{"type":"terminal","env":{"ZDOTDIR":"/tmp/evil"}}]}}}}]}
        """)

        let summary = ProgramaConfigExecutor.describeForConfirmation(command)

        XCTAssertTrue(summary.contains("ZDOTDIR"), "env key must be visible, got:\n\(summary)")
        XCTAssertTrue(summary.contains("/tmp/evil"), "env value must be visible, got:\n\(summary)")
    }

    func testCwdOnlySurfaceIsDisclosed() throws {
        let command = try decodeCommand("""
        {"commands":[{"name":"x","workspace":{"name":"dev",
        "layout":{"pane":{"surfaces":[{"type":"terminal","cwd":"/tmp/elsewhere"}]}}}}]}
        """)

        XCTAssertTrue(ProgramaConfigExecutor.describeForConfirmation(command).contains("/tmp/elsewhere"))
    }

    /// A parameterised `command:` entry must disclose the substituted value, not the raw
    /// `{{name}}` template -- same principle as the recipe path, applied to plain commands.
    func testParameterisedCommandDisclosesSubstitutedValueNotTemplate() throws {
        let command = try decodeCommand("""
        {"commands":[{"name":"Checkout branch","command":"git checkout {{branch}}",
        "parameters":[{"name":"branch","prompt":"Branch name"}]}]}
        """)

        let substituted = ProgramaConfigExecutor.substituteParameters(
            in: try XCTUnwrap(command.command),
            values: ["branch": "release/9.0"]
        )
        let summary = ProgramaConfigExecutor.describeForConfirmation(command, resolvedCommand: substituted)

        XCTAssertEqual(summary, "git checkout release/9.0")
        XCTAssertFalse(summary.contains("{{branch}}"))
    }

    func testEverySurfaceInASplitIsDisclosed() throws {
        let command = try decodeCommand("""
        {"commands":[{"name":"x","workspace":{"name":"dev","layout":{"direction":"horizontal","children":[
        {"pane":{"surfaces":[{"type":"terminal","command":"first-thing"}]}},
        {"pane":{"surfaces":[{"type":"terminal","env":{"BASH_ENV":"/tmp/second-thing"}}]}}]}}}]}
        """)

        let summary = ProgramaConfigExecutor.describeForConfirmation(command)

        XCTAssertTrue(summary.contains("first-thing"), "got:\n\(summary)")
        XCTAssertTrue(summary.contains("BASH_ENV"), "a nested branch must not be skipped, got:\n\(summary)")
        XCTAssertTrue(summary.contains("/tmp/second-thing"), "got:\n\(summary)")
    }

    /// A crafted value must not be able to push the real payload out of the alert's
    /// non-scrolling text area.
    func testLongValueIsTruncated() throws {
        let padding = String(repeating: "A", count: 5000)
        let command = try decodeCommand("""
        {"commands":[{"name":"x","workspace":{"name":"dev",
        "layout":{"pane":{"surfaces":[{"type":"terminal","command":"\(padding)"}]}}}}]}
        """)

        let summary = ProgramaConfigExecutor.describeForConfirmation(command)

        XCTAssertLessThan(summary.count, 1000, "a 5000-char value must not reach the dialog whole")
    }

    /// Newlines inside one value must be collapsed, or a value can fake extra dialog lines.
    func testNewlinesInsideAValueAreCollapsed() throws {
        let command = try decodeCommand("""
        {"commands":[{"name":"x","workspace":{"name":"dev","layout":{"pane":{"surfaces":
        [{"type":"terminal","command":"real-cmd\\n\\n\\n\\n\\n\\n\\n\\n\\n\\nCancel to continue"}]}}}}]}
        """)

        let summary = ProgramaConfigExecutor.describeForConfirmation(command)
        let blankRun = summary.contains("\n\n\n")

        XCTAssertFalse(blankRun, "a single value must not inject blank lines, got:\n\(summary)")
        XCTAssertTrue(summary.contains("real-cmd"))
    }
}

// MARK: - Parameter substitution

@MainActor
final class ProgramaConfigParameterSubstitutionTests: XCTestCase {
    func testSubstitutesDeclaredParameters() {
        let result = ProgramaConfigExecutor.substituteParameters(
            in: "git checkout {{branch}}",
            values: ["branch": "feature/thing"]
        )
        XCTAssertEqual(result, "git checkout feature/thing")
    }

    func testSubstitutesMultipleOccurrencesOfSameParameter() {
        let result = ProgramaConfigExecutor.substituteParameters(
            in: "echo {{name}} && echo {{name}} again",
            values: ["name": "hi"]
        )
        XCTAssertEqual(result, "echo hi && echo hi again")
    }

    func testUndeclaredPlaceholderIsLeftLiteral() {
        // {{name}} is declared and substituted; {{other}} is not declared anywhere and must
        // survive untouched, braces and all -- not stripped, not errored.
        let result = ProgramaConfigExecutor.substituteParameters(
            in: "hello {{name}}, unresolved: {{other}}",
            values: ["name": "world"]
        )
        XCTAssertEqual(result, "hello world, unresolved: {{other}}")
    }

    func testNoParametersLeavesTemplateUnchanged() {
        let result = ProgramaConfigExecutor.substituteParameters(
            in: "no placeholders here",
            values: [:]
        )
        XCTAssertEqual(result, "no placeholders here")
    }

    func testEmptyValuesDictLeavesAllPlaceholdersLiteral() {
        let result = ProgramaConfigExecutor.substituteParameters(
            in: "run {{task}}",
            values: [:]
        )
        XCTAssertEqual(result, "run {{task}}")
    }
}

// MARK: - Recipe disclosure
//
// Mirrors `ProgramaConfigConsentDisclosureTests` for the recipe path: the dialog must show the
// fully parameter-substituted prompt (what actually gets typed into the terminal), never the
// recipe's name and never its raw `{{name}}` template -- that would let a config author (or an
// attacker who controls a cloned repo's programa.json) hide the real payload behind an
// innocuous-looking recipe name.
@MainActor
final class ProgramaConfigRecipeDisclosureTests: XCTestCase {
    private func decodeRecipe(_ json: String) throws -> ProgramaRecipeDefinition {
        let file = try JSONDecoder().decode(ProgramaConfigFile.self, from: Data(json.utf8))
        return try XCTUnwrap(file.recipes?.first)
    }

    func testDescribeForConfirmationShowsSubstitutedPromptNotTemplate() throws {
        let recipe = try decodeRecipe("""
        {"commands":[],"recipes":[{"name":"Refactor helper","prompt":"Refactor {{file}} to use hooks",
        "parameters":[{"name":"file","prompt":"File"}]}]}
        """)

        let substituted = ProgramaConfigExecutor.substituteParameters(
            in: recipe.prompt,
            values: ["file": "Sources/Widget.swift"]
        )
        let summary = ProgramaConfigExecutor.describeForConfirmation(recipe, resolvedPrompt: substituted)

        XCTAssertTrue(
            summary.contains("Sources/Widget.swift"),
            "the substituted value must be visible, got:\n\(summary)"
        )
        XCTAssertFalse(
            summary.contains("{{file}}"),
            "the raw template must never reach the dialog, got:\n\(summary)"
        )
        XCTAssertFalse(
            summary.contains("Refactor helper"),
            "the recipe's name must not stand in for its actual payload, got:\n\(summary)"
        )
    }

    func testDescribeForConfirmationDoesNotLeakUnsubstitutedTemplateWhenNoValuesGiven() throws {
        // Even if a caller forgot to substitute (which should never happen given `execute`'s
        // ordering), the disclosure text is driven entirely by the caller-supplied
        // `resolvedPrompt` argument -- there is no path back to the raw recipe definition once
        // this is called with a resolved string that has already had substitution applied.
        let recipe = try decodeRecipe("""
        {"commands":[],"recipes":[{"name":"x","prompt":"do {{thing}}"}]}
        """)
        let substituted = ProgramaConfigExecutor.substituteParameters(in: recipe.prompt, values: ["thing": "the work"])

        XCTAssertEqual(
            ProgramaConfigExecutor.describeForConfirmation(recipe, resolvedPrompt: substituted),
            "do the work"
        )
    }
}

/// What gets typed into the terminal and what gets drawn in the confirmation dialog are two
/// different jobs, and conflating them shipped a real bug: `sanitizeForDisplay` grew newline
/// collapsing and a 200-character cap to stop a crafted value flooding the alert, but `execute`
/// was also running it over the command on its way to the shell. From 3f97866968 until the
/// split, any programa.json command longer than 200 characters was silently truncated and
/// executed with "… (truncated)" glued onto the end of it.
@MainActor
final class ProgramaConfigExecutionSanitizerTests: XCTestCase {
    func testRecipeRejectsControlsAndLineBreaksIncludingSubstitutedParametersBeforeSendingAnything() {
        let unsafeValues = [
            "first\rsecond", "first\nsecond", "first\r\nsecond", "first\tsecond",
            "first\u{001B}[31msecond", "first\u{0000}second", "first\u{007F}second",
            "first\u{0085}second", "first\u{009B}second", "first\u{2028}second", "first\u{2029}second",
        ]
        for (index, value) in unsafeValues.enumerated() {
            let substituted = ProgramaConfigExecutor.substituteParameters(
                in: "Review {{subject}}", values: ["subject": value]
            )
            for prompt in [value, substituted] {
                var sent: [String] = []
                let accepted = ProgramaConfigExecutor.insertRecipePrompt(prompt) { sent.append($0) }
                XCTAssertFalse(accepted, "Unsafe recipe case \(index) must require correction before terminal insertion")
                XCTAssertTrue(sent.isEmpty, "Recipe case \(index) must not partially submit or alter terminal input")
            }
        }
    }

    func testRecipeInsertsLongSingleLineUnicodePromptExactlyOnceWithoutSubmitting() {
        let prompt = "変更を説明してください 🧭 " + String(repeating: "café 世界 ", count: 128)
        var sent: [String] = []

        XCTAssertTrue(ProgramaConfigExecutor.insertRecipePrompt(prompt) { sent.append($0) })
        XCTAssertEqual(sent, [prompt], "The user must receive the entire prompt for review, without an appended Return")
    }

    func testRecipeRemovesMisleadingScalarsWhilePreservingIntentionalWhitespace() {
        let prompt = "  Review \u{202E}\u{200B}café 世界  "
        var sent: [String] = []

        XCTAssertTrue(ProgramaConfigExecutor.insertRecipePrompt(prompt) { sent.append($0) })
        XCTAssertEqual(sent, ["  Review café 世界  "],
                       "A safe recipe must reach the terminal once without hidden direction changes, trimming, or submission")
    }

    /// The regression. A long-but-ordinary command has to survive intact.
    func testLongCommandIsNotTruncatedOnItsWayToTheShell() {
        let command = "echo " + String(repeating: "x", count: 500)

        let sent = ProgramaConfigExecutor.sanitizeForExecution(command)

        XCTAssertEqual(sent, command, "a 505-char command must reach the shell whole")
        XCTAssertFalse(sent.contains("truncated"), "the display truncation marker must never be executed")
    }

    /// Multi-line values are legitimate for recipe prompts and heredocs alike.
    func testNewlinesSurviveExecutionSanitizing() {
        let text = "line one\nline two\nline three"

        XCTAssertEqual(ProgramaConfigExecutor.sanitizeForExecution(text), text)
    }

    /// The one thing it must still do: strip scalars that make text misrepresent itself.
    func testBidiAndZeroWidthScalarsAreStillStripped() {
        let sneaky = "rm -rf /\u{202E}\u{200B} harmless"

        let sent = ProgramaConfigExecutor.sanitizeForExecution(sneaky)

        XCTAssertFalse(sent.unicodeScalars.contains("\u{202E}"), "bidi override must be stripped")
        XCTAssertFalse(sent.unicodeScalars.contains("\u{200B}"), "zero-width space must be stripped")
    }

    /// The display path keeps its bound -- the split must not have loosened it.
    func testDisplayPathStillTruncates() throws {
        let padding = String(repeating: "A", count: 5000)
        let file = try JSONDecoder().decode(
            ProgramaConfigFile.self,
            from: Data("""
            {"commands":[{"name":"x","workspace":{"name":"dev",
            "layout":{"pane":{"surfaces":[{"type":"terminal","command":"\(padding)"}]}}}}]}
            """.utf8)
        )
        let command = try XCTUnwrap(file.commands.first)

        XCTAssertLessThan(ProgramaConfigExecutor.describeForConfirmation(command).count, 1000)
    }
}
