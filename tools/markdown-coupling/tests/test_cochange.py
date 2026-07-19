"""Output-based tests for the co-change pure core (axis 2).

Khorikov: the functional core is a pure function of (git-log text, support floor),
so these assert on returned values, not on mocks or internal state. The fixture log
has KNOWN co-change pairs so every count is hand-verifiable.
"""

import pytest

import cochange

# Synthetic git-log dump in measure.sh's `--pretty=format:'__COMMIT__%H' --name-only` shape.
# Known structure:
#   (a,b): commits aaa, bbb, ccc      -> support 3
#   (a,c): commits bbb, eee           -> support 2
#   (b,c): commit  bbb                -> support 1
#   file support: a=4, b=3, c=2, x=1  | commits: 5 total, 4 multi-file (ddd is single)
FIXTURE_LOG = """\
__COMMIT__aaa
docs/a.md
docs/b.md

__COMMIT__bbb
docs/a.md
docs/b.md
docs/c.md

__COMMIT__ccc
docs/b.md
docs/a.md

__COMMIT__ddd
docs/x.md

__COMMIT__eee
docs/a.md
docs/c.md
"""


@pytest.fixture
def floor2_report():
    """Co-change report over FIXTURE_LOG at support_floor=2. Reused by the tests that
    assert on its counts, pairs, and degrees; each expected value stays inline at the
    call site so every number remains hand-verifiable there."""
    return cochange.cochange_report(
        cochange.parse_commits(FIXTURE_LOG), support_floor=2
    )


def test_parse_commits_groups_files_per_commit_sorted():
    commits = cochange.parse_commits(FIXTURE_LOG)
    assert commits == [
        ["docs/a.md", "docs/b.md"],
        ["docs/a.md", "docs/b.md", "docs/c.md"],
        ["docs/a.md", "docs/b.md"],  # ccc listed b before a -> parse sorts it
        ["docs/x.md"],
        ["docs/a.md", "docs/c.md"],
    ]


def test_parse_commits_empty_log_is_empty():
    assert cochange.parse_commits("") == []


def test_report_counts_commits_and_multifile(floor2_report):
    assert floor2_report["n_commits"] == 5
    assert floor2_report["n_multi"] == 4


def test_report_pairs_above_floor_with_support_and_confidence(floor2_report):
    # support 3 sorts before support 2; (b,c) support-1 is below the floor and excluded.
    assert floor2_report["pairs"] == [
        {
            "a": "docs/a.md",
            "b": "docs/b.md",
            "support": 3,
            "conf_a_to_b": 0.75,  # 3 / support(a)=4
            "conf_b_to_a": 1.0,  # 3 / support(b)=3
        },
        {
            "a": "docs/a.md",
            "b": "docs/c.md",
            "support": 2,
            "conf_a_to_b": 0.5,  # 2 / support(a)=4
            "conf_b_to_a": 1.0,  # 2 / support(c)=2
        },
    ]


def test_report_degree_counts_distinct_above_floor_partners(floor2_report):
    degrees = {d["file"]: d["degree"] for d in floor2_report["degrees"]}
    assert degrees == {"docs/a.md": 2, "docs/b.md": 1, "docs/c.md": 1}


def test_default_support_floor_is_three_excludes_support_two_pair():
    report = cochange.cochange_report(cochange.parse_commits(FIXTURE_LOG))
    # default floor 3 keeps only (a,b); (a,c) support-2 drops out.
    assert [(p["a"], p["b"]) for p in report["pairs"]] == [("docs/a.md", "docs/b.md")]


def test_section_empty_window_reports_no_pairs():
    section = cochange.cochange_section("", since="deadbeef")
    assert "## Axis 2 — co-change coupling" in section
    assert "No co-change pairs" in section


def test_section_is_deterministic():
    a = cochange.cochange_section(FIXTURE_LOG, support_floor=2)
    b = cochange.cochange_section(FIXTURE_LOG, support_floor=2)
    assert a == b
    assert "`docs/a.md`" in a and "`docs/b.md`" in a
