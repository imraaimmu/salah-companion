# Contributing to Salah Companion

Jazakum Allahu khairan for helping. This guide covers how to contribute and the few
rules that protect the people who will pray with this app.

## Ground rules

1. **Privacy is not negotiable.** No network code, analytics, crash reporting, ads,
   accounts or SDKs that send data. No code that writes camera frames to storage. CI
   enforces part of this; reviewers enforce the rest.
2. **Never wrong-time audio.** Any change to detection, smoothing or the state machine
   must pass the full replay test suite with zero wrong-time audio events.
3. **Religious content needs review.** Changes to surah lists, recitation order,
   timings tied to the prayer, or wording about prayer need sign-off from a reviewer with
   the `religious-review` role, not just code review.
4. **Respect.** Follow the [Code of Conduct](CODE_OF_CONDUCT.md). Differences between
   madhhabs are discussed with adab; the app aims to serve all of them.

## Licence of contributions

By contributing, you agree that your contribution is licensed under the same terms as
the project: the [PolyForm Noncommercial License 1.0.0](LICENSE) plus the
[Additional Terms](ADDITIONAL-TERMS.md). No one, including the maintainers, may sell it.

Sign off every commit to certify the [Developer Certificate of Origin](https://developercertificate.org/):

```
git commit -s -m "Describe your change"
```

Only contribute work you wrote yourself or have the right to submit. Do not add
recitation audio, Quran text, translations or fonts from other sources without opening an
issue first, so their licences can be checked.

## How to contribute

1. Pick an issue, or open one describing what you want to change. Comment to claim it.
2. Read the relevant section of [docs/SPEC.md](docs/SPEC.md). Each issue links its
   section and states its acceptance criteria.
3. Work behind the interfaces in the spec's "Technical architecture" section. If an
   interface needs to change, propose it in the issue first.
4. Open a pull request using the template. Keep it focused on one issue.
5. A different person (or review agent) reviews it against the issue's acceptance
   criteria and runs the replay tests.

## Ways to help without writing code

- **Test on your phone** and report frame rate and detection quality (issue label
  `needs-device`).
- **Record test prayers** with the internal test app once it exists. It saves body-point
  numbers only, never video. Recordings are voluntary and need your explicit consent.
- **Fiqh review**: check timings, surah pairs and wording (`religious-review`).
- **Translations** of the interface (`translation`).

## Labels

| Label | Meaning |
| --- | --- |
| `W1-pose` ... `W7-qa` | Workstream from the spec |
| `good first issue` | Small and well defined |
| `needs-device` | Needs a real phone to test |
| `religious-review` | Needs review by someone with fiqh knowledge |
| `spike` | Time-boxed investigation that ends in a written note |
| `privacy` | Touches the privacy promises |
| `legal` | Licensing or trademark |
