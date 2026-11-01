use std::env;

#[derive(Default)]
struct PaneStatus {
    direnv: bool,
    nix: Option<String>,
    branch: Option<String>,
    user: Option<String>,
    files: Option<u64>,
    added: Option<u64>,
    deleted: Option<u64>,
}

fn main() {
    let mut args = env::args().skip(1);
    match args.next().as_deref() {
        Some("right") => {
            let status = args.next().unwrap_or_default();
            print!("{}", render_right(&parse_status(&status)));
        }
        Some("help") | Some("-h") | Some("--help") => {
            print_help();
        }
        _ => {
            eprintln!("Usage: hey-tmux-status right PANE_STATUS");
            std::process::exit(2);
        }
    }
}

fn print_help() {
    println!("Usage: hey-tmux-status right PANE_STATUS");
    println!();
    println!("PANE_STATUS is a tab-separated list of key=value pairs:");
    println!(
        "  direnv=1\\tnix=impure\\tbranch=master\\tuser=example-user\\tfiles=3\\tadded=10\\tdeleted=2"
    );
}

fn parse_status(input: &str) -> PaneStatus {
    let mut status = PaneStatus::default();

    for field in input.split('\t') {
        let Some((key, value)) = field.split_once('=') else {
            continue;
        };

        match key {
            "direnv" => status.direnv = value == "1" || value == "true",
            "nix" if !value.is_empty() => status.nix = Some(value.to_owned()),
            "branch" if !value.is_empty() => status.branch = Some(value.to_owned()),
            "user" if !value.is_empty() => status.user = Some(value.to_owned()),
            "files" => status.files = parse_nonzero(value),
            "added" => status.added = parse_nonzero(value),
            "deleted" => status.deleted = parse_nonzero(value),
            _ => {}
        }
    }

    status
}

fn parse_nonzero(value: &str) -> Option<u64> {
    value.parse::<u64>().ok().filter(|n| *n != 0)
}

fn render_right(status: &PaneStatus) -> String {
    let mut parts = Vec::new();

    if status.direnv {
        parts.push("#[range=user|direnv]▼#[norange]".to_owned());
    }
    if let Some(nix) = &status.nix {
        parts.push(format!(
            "#[range=user|nix]nix {}#[norange]",
            escape_tmux(nix)
        ));
    }
    if let Some(branch) = &status.branch {
        let mut git = vec![format!("#[fg=colour5]{}#[fg=colour8]", escape_tmux(branch))];
        if let Some(user) = &status.user {
            git.push(format!("#[fg=colour6]@{}#[fg=colour8]", escape_tmux(user)));
        }
        if let Some(files) = status.files {
            git.push(format!("#[fg=colour3]~{}#[fg=colour8]", files));
        }
        if let Some(added) = status.added {
            git.push(format!("#[fg=colour2]+{}#[fg=colour8]", added));
        }
        if let Some(deleted) = status.deleted {
            git.push(format!("#[fg=colour1]-{}#[fg=colour8]", deleted));
        }
        parts.push(format!("#[range=user|git]{}#[norange]", git.join(" ")));
    } else {
        if let Some(files) = status.files {
            parts.push(format!("#[fg=colour3]~{}#[fg=colour8]", files));
        }
        if let Some(added) = status.added {
            parts.push(format!("#[fg=colour2]+{}#[fg=colour8]", added));
        }
        if let Some(deleted) = status.deleted {
            parts.push(format!("#[fg=colour1]-{}#[fg=colour8]", deleted));
        }
    }

    parts.join(" ")
}

fn escape_tmux(input: &str) -> String {
    input.replace('#', "##")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn renders_compact_right_status() {
        let status =
            parse_status("direnv=1\tnix=impure\tbranch=master\tuser=example-user\tfiles=6\tadded=42\tdeleted=9");

        assert_eq!(
            render_right(&status),
            "#[range=user|direnv]▼#[norange] #[range=user|nix]nix impure#[norange] #[range=user|git]#[fg=colour5]master#[fg=colour8] #[fg=colour6]@example-user#[fg=colour8] #[fg=colour3]~6#[fg=colour8] #[fg=colour2]+42#[fg=colour8] #[fg=colour1]-9#[fg=colour8]#[norange]"
        );
    }

    #[test]
    fn skips_empty_and_zero_fields() {
        let status = parse_status("direnv=0\tnix=\tbranch=main\tfiles=0\tadded=0\tdeleted=0");

        assert_eq!(render_right(&status), "#[range=user|git]#[fg=colour5]main#[fg=colour8]#[norange]");
    }

    #[test]
    fn escapes_tmux_format_markers() {
        let status = parse_status("branch=feature#1\tuser=user#1");

        assert_eq!(
            render_right(&status),
            "#[range=user|git]#[fg=colour5]feature##1#[fg=colour8] #[fg=colour6]@user##1#[fg=colour8]#[norange]"
        );
    }
}
