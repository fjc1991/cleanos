# Security

CleanOS removes files and, when you allow it, runs a small helper with administrator rights. Please report
anything that could make it remove the wrong thing or let another program use those rights.

**Report privately** through GitHub: open the repository's **Security** tab and choose **Report a
vulnerability**. Please do not open a public issue for security problems. Include the CleanOS version
(Settings → About), the macOS version and the steps to reproduce.

What the administrator side accepts is deliberately narrow, and worth knowing when you look for problems:

- The helper (`Helper/main.swift`, `Packages/HelperProtocol`) refuses system locations, home and Library
  folders and other shared folders itself (`ProtectedPaths`), whatever the app asks.
- It runs only a short list of tools with the exact arguments CleanOS uses (`ToolPolicy`).
- The installed helper accepts connections only from a CleanOS signed with the same certificate, checked
  by the system against the connection's audit token. The password-prompt path copies the helper into a
  root-only folder and checks its signature before running it.
- Updates are accepted only when signed with the project's Sparkle key.
