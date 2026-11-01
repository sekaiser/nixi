# Nix-managed Codex skills

The Codex module manages only explicitly selected skill directories. Mutable
Codex config, authentication, plugins and unrelated skills are left alone.

```nix
modules.agents.codex = {
  enable = true;
  skills = {
    design-taste-frontend = hey.packages.taste-skill;
    humanizer = hey.packages.humanizer;
  };
};
```

The mapping accepts skill packages or source directories containing `SKILL.md`.
The default destination is `${home.dir}/.agents/skills`, the current Codex
user-scope discovery directory. `skillsDirectory` can select another canonical
directory inside the user's home. Home Manager links each selected folder into
place; it does not replace the whole skills directory or forcibly overwrite
existing user files. Existing conflicting folders must be resolved explicitly.

Apply the host configuration, then start a new Codex turn. Invoke
`$design-taste-frontend` for frontend design or `$humanizer` for prose editing.
If the client does not refresh discovery automatically, restart it.

Both packages pin a Git revision and source hash. Taste installs the default
`design-taste-frontend` skill only (upstream v2 is currently experimental), not
the repository's other design/image skills. Humanizer includes its `agents/`
metadata. Upstream instruction files remain unchanged; licenses are included.
No upstream installer, plugin hook, or package-manager lifecycle script is run
by Nix. Installing these instructions does not grant them additional permissions.
Taste may recommend dependencies or external image sources during frontend work;
those remain subject to the user's task and the agent's normal approval policy.

Consumers opt in; neither skill is enabled by the generic module. Keep personal
skill content outside public mechanism sources. Nix copies skill sources into
the store, so never supply credentials or private notes as skill source files.

References: [Codex skill discovery](https://learn.chatgpt.com/docs/build-skills),
[Taste](https://github.com/Leonxlnx/taste-skill),
[Humanizer](https://github.com/blader/humanizer).
