# CI gate example

The canonical GitHub Actions workflow template is `lib/templates/signum-gate.yml`. Copy or adapt that template for a repository; do not fork a separate workflow source from this example.

The template runs the CI wrapper:

```bash
bash lib/signum-ci.sh
```

`lib/signum-ci.sh` validates the produced proofpack and maps Signum decisions to CI exit codes:

| Exit code | Decision |
| --- | --- |
| `0` | `AUTO_OK` |
| `1` | `AUTO_BLOCK` |
| `78` | `HUMAN_REVIEW` |

Use `docs/reference.md` for full CI behavior and artifact details.
