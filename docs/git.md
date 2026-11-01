# Git Configuration

The Git module is the generic mechanism for rendering Git configuration on a
host. It should not know about private project names, work profiles, or a
specific secret backend.

## Structured Config

Prefer configuring `git/config` through structured Nix options:

```nix
modules.shell.git = {
  enable = true;

  config = {
    includes = [
      {
        condition = "gitdir:**/github.com/**/.git";
        path = "github";
      }
    ];

    sections = [
      {
        name = "user";
        settings = {
          name = "Example User";
          email = "user@example.invalid";
        };
      }
      {
        name = "url";
        subsection = "ssh://git@github.com/";
        entries = [
          {
            name = "insteadOf";
            value = "https://github.com/";
          }
        ];
      }
    ];
  };
};
```

`config.sections.*.settings` is convenient for normal one-value keys.
`config.sections.*.entries` preserves order and supports duplicate keys, which
Git allows in sections such as `url` and `remote`.

Use `config.extraSections` or `config.extraText` only when Git supports syntax
that the structured renderer does not model yet.

## Profile Files

Additional config snippets can be written below `~/.config/git`:

```nix
modules.shell.git.profileFiles.work.text = ''
  [user]
      name = Example User
      email = user@example.invalid
'';
```

Use `profileFiles.<name>.source` instead of `text` when the snippet already
exists as a file.

## Secrets

Profile-specific secret material can be installed below `~/.config/git` without
coupling the Git module to a secret backend:

```nix
modules.shell.git.secrets.work = {
  target = "work_secret";
  sourceFile = config.sops.secrets."git/work_token".path;
};

modules.shell.git.secrets.local = {
  target = "local_secret";
  sourceFile = "/run/secrets/git/local_token";
};
```

Hosts decide whether `sourceFile` comes from SOPS, age, a manually managed file,
or another backend. The Git module only copies the declared runtime file; it does
not accept inline secret text, so secret material does not enter activation
script text.

`sourceFile` must be a canonical absolute runtime path. Activation copies run
with privileged source access, so the entire source traversal must be protected:
root-owned directories without group/world write access, and a regular file
owned by root or the recipient without group/world write access. Protected
secret-provider generation symlinks are supported. Do not point this option
into a user-writable home or shared temporary directory; stage the source with
your system secret provider instead. Do not grant untrusted write access via
ACLs. Invalid sources fail before replacing the existing installed secret.

## Private Configs

Private work/project conventions should live in host or private modules, not in
the generic Git module. A private module may still read custom files such as
`projects.json` or `git-secrets.json`, but it should translate them into the
generic mechanism options:

- `config.includes`
- `config.sections`
- `config.extraSections`
- `profileFiles`
- `secrets`
