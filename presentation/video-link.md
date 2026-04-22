# Presentation Video

| Field         | Value                                                  |
| ------------- | ------------------------------------------------------ |
| **YouTube URL** | <paste unlisted YouTube link here before submission> |
| **Duration**  | 10-15 minutes                                          |
| **Presenter** | Trevor Kutto (041164341)                               |
| **Recorded**  | <date>                                                 |

## Contents

The video walks through `presentation/slides.pptx` and includes live demos of:

1. Version A - deployed `func-cst8917-durable-4dad68`, three scenarios (A-1 auto-approve, A-2 manager approve, A-3 escalation) driven from PowerShell via `demo/prime.ps1` helpers (`Start-Exp`, `Get-Stat`, `Send-Dec`).
2. Version B - Service Bus queue `expense-requests`, `logic-cst8917-main` and the three notifier Logic Apps. B-1 auto-approve via `Send-SB`, B-2 + B-3 approve/reject via `demo/test-version-b-approval.ps1`, B-4 escalation explained from the designer (10-min timeout, too long to wait on camera).

## Recording notes

- Screen + audio captured with OBS Studio.
- Slides authored in PowerPoint (`slides.pptx`); outline also kept in `slides.md` for source control.
- Uploaded as **unlisted** on YouTube (accessible via URL, not discoverable).
