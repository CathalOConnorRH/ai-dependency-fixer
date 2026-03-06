# AI Dependency Fixer — Logic Flow

```mermaid
flowchart TD
    A["PR opened/updated"] --> B{"PR author is<br/>Renovate or Dependabot?"}
    B -- No --> Z["Skip — not a dependency bot"]
    B -- Yes --> C["Set up Python"]
    C --> D["Install AI provider SDK<br/>(anthropic or openai)"]
    D --> E["Detect language,<br/>test & install commands"]
    E --> F["Install required tooling<br/>(Poetry, pnpm, Bundler if needed)"]
    F --> G["Install project dependencies"]
    G --> H["Run tests"]

    H --> I{"Tests pass?"}
    I -- Yes --> J["✅ Exit: already-passing"]

    I -- No --> K["Initialize attempt = 1"]
    K --> L["Gather context<br/>(dep diff, errors, source files)"]
    L --> M["Call LLM for fix<br/>(Anthropic / OpenAI / self-hosted)"]

    M --> N{"API call<br/>succeeded?"}
    N -- No --> R["Revert changes"]

    N -- Yes --> O["Validate response<br/>(safety checks)"]
    O --> P{"Valid?"}
    P -- No --> R

    P -- Yes --> Q["Apply edits to source files"]
    Q --> S{"Edits applied<br/>successfully?"}
    S -- No --> R

    S -- Yes --> T["Re-install dependencies"]
    T --> U["Run tests"]
    U --> V{"Tests pass?"}

    V -- Yes --> W["Commit & push fix"]
    W --> X["Post PR comment: ✅ fixed"]
    X --> Y["✅ Exit: fixed"]

    V -- No --> R
    R --> AA["Save attempt to history"]
    AA --> AB{"Attempts<br/>< max?"}
    AB -- Yes --> AC["attempt += 1"] --> L
    AB -- No --> AD["Revert all changes"]
    AD --> AE["Post PR comment: ❌ needs manual fix"]
    AE --> AF["❌ Exit: failed"]

    style J fill:#22c55e,color:#fff
    style Y fill:#22c55e,color:#fff
    style AF fill:#ef4444,color:#fff
    style Z fill:#6b7280,color:#fff
```
