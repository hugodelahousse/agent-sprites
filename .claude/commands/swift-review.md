# Swift Code Review

Review Swift/SwiftUI code against the standards defined in CLAUDE.md.

## Usage
- `/swift-review` — Review entire codebase
- `/swift-review src/AgentSprites/` — Review specific directory
- `/swift-review Sources/AgentSpritesCore/Models/` — Review specific module

## Instructions

Review the specified code (or entire `Sources/` if no path given) against the Swift Standards in CLAUDE.md. For each file, check:

1. **Concurrency**: async/await usage, actor isolation, @MainActor placement
2. **Value Types**: struct vs class justification
3. **Logging**: os.Logger usage, subsystem naming, privacy annotations
4. **Serialization**: Codable patterns, no manual JSON parsing
5. **Persistence**: UserDefaults appropriateness, no sensitive data exposure
6. **SwiftUI**: View extraction, property wrapper correctness, modern APIs
7. **Error Handling**: Typed errors, no empty catches
8. **Safety**: Force unwraps, force casts

## Output Format

Structure the review as:

### Summary
One paragraph overall assessment of code quality and adherence to standards.

### Critical Issues
Bugs, crashes, or security problems requiring immediate attention.

For each issue:
- **Location**: `File.swift:123` or `File.swift:functionName()`
- **Issue**: What's wrong
- **Fix**: Concrete code suggestion
- **Reference**: Link to SE proposal or Apple docs if relevant

### Modernization Opportunities
Older patterns that could use modern Swift idioms. Same format as Critical Issues.

### Style & Consistency
Deviations from project's established patterns (subsystem naming, timestamp() usage, etc.).

### Positive Highlights
Things done well — reinforces good practices and team morale.

## Example Output

```
### Summary
The networking module demonstrates solid async/await adoption but has inconsistent error handling...

### Critical Issues
None identified.

### Modernization Opportunities
**Location**: `APIClient.swift:45`
**Issue**: Uses completion handler pattern
**Fix**:
\`\`\`swift
// Before
func fetchUser(id: String, completion: @escaping (Result<User, Error>) -> Void)

// After
func fetchUser(id: String) async throws -> User
\`\`\`
**Reference**: SE-0296 async/await

### Style & Consistency
- Logger subsystem uses "com.app" instead of "com.agentsprites.app"

### Positive Highlights
- Excellent use of Codable with custom CodingKeys
- Proper @MainActor annotation on view models
```
