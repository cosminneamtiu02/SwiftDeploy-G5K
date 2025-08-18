name: "🐛 Bug report"
description: Report something that isn't working as expected
title: "bug: <short description>"
labels: ["bug", "not fixed"]
assignees:
  - cosminneamtiu02

body:
  - type: textarea
    id: summary
    attributes:
      label: Summary
      description: A clear and concise description of the problem.
      placeholder: e.g. "The script fails when run on Grid'5000 frontend"
    validations:
      required: true

  - type: textarea
    id: steps
    attributes:
      label: Steps to Reproduce
      description: How can we reproduce this issue?
      placeholder: |
        1. Log in to frontend
        2. Run command ...
        3. Observe error
    validations:
      required: true

  - type: input
    id: expected
    attributes:
      label: Expected Behavior
      description: What did you expect to happen?
    validations:
      required: true

  - type: textarea
    id: actual
    attributes:
      label: Actual Behavior
      description: What actually happened? (logs, screenshots, etc.)
    validations:
      required: true

  - type: dropdown
    id: status
    attributes:
      label: Bug Status
      description: Track the current status of this bug.
      options:
        - not fixed
        - fixed
        - in progress
        - blocked
        - requires info
        - done
    validations:
      required: false

  - type: textarea
    id: env
    attributes:
      label: Environment
      description: Provide environment details.
      placeholder: |
        - Grid'5000 site/region:
        - OS / image:
        - Shell:
        - Commit/branch:
