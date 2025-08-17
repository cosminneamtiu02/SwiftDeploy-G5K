# grid5k-MLRW

[![Shell Quality](https://github.com/cosminneamtiu02/grid5k-MLRW/actions/workflows/shell-quality.yml/badge.svg)](https://github.com/cosminneamtiu02/grid5k-MLRW/actions/workflows/shell-quality.yml)

[![pre-commit.ci status](https://img.shields.io/endpoint?url=https://badge.pre-commit.ci/https://github.com/cosminneamtiu02/grid5k-MLRW/main)](https://pre-commit.ci/)

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

This repository provides an infrastructure for Grid'5000, supporting and accelerating multiple parallel and synchronous machine learning trainings. It also includes tools for building images and offers a standardized approach for collecting results on the platform.



## Grid'5000: Setup & Update Guide

Follow these steps to get this project onto a Grid'5000 Frontend (FE) and keep it up to date.

### 1) Prerequisites

- You have a Grid'5000 account and your SSH key is registered.  
- Replace `YOUR_LOGIN` and `YOUR_SITE` with your own values.

### 2) Log in to a Frontend (FE)

Option A — via the access gateway (recommended):

```bash
ssh YOUR_LOGIN@access.grid5000.fr
# then hop to a site FE (aka "region"), for example:
ssh YOUR_LOGIN@nancy.grid5000.fr
```

Option B — direct to a site FE:

```bash
ssh YOUR_LOGIN@rennes.grid5000.fr
```

Common site FEs:
grenoble.grid5000.fr, lille.grid5000.fr, luxembourg.grid5000.fr, lyon.grid5000.fr,
nancy.grid5000.fr, nantes.grid5000.fr, reims.grid5000.fr, rennes.grid5000.fr,
sophia.grid5000.fr, toulouse.grid5000.fr

### 3) Choose a working folder on the FE

Create (or reuse) a workspace directory for this project:

```bash
mkdir -p $HOME/work/grid5k-MLRW
cd $HOME/work/grid5k-MLRW
```

### 4) Clone this repository (first time)

HTTPS (read-only; works for everyone):

```bash
git clone https://github.com/cosminneamtiu02/grid5k-MLRW.git
cd grid5k-MLRW
```

If you have push rights and prefer SSH:

```bash
git remote set-url origin git@github.com:cosminneamtiu02/grid5k-MLRW.git
```

### 5) Update to the latest version (next times)

From the FE workspace:

```bash
cd $HOME/work/grid5k-MLRW/grid5k-MLRW
git pull --ff-only
```

If you have local edits and want to keep them:

```bash
git stash
git pull --ff-only
git stash pop
```

### 6) One-liner: clone if missing, otherwise update

Run this in your workspace directory:

```bash
cd $HOME/work/grid5k-MLRW
if [ -d grid5k-MLRW/.git ]; then
  git -C grid5k-MLRW pull --ff-only
else
  git clone https://github.com/cosminneamtiu02/grid5k-MLRW.git
fi
```

### 7) (Optional) Keep per-site work separated

If you work across multiple sites, you can keep a per-site folder:

```bash
export G5K_SITE=nancy
mkdir -p $HOME/work/$G5K_SITE/grid5k-MLRW
cd $HOME/work/$G5K_SITE/grid5k-MLRW
# then clone/update as above
```


## Contributing

We welcome contributions! 🎉  

Please read the [Contributing Guide](./CONTRIBUTING.md) for setup instructions, coding standards, and our pull request workflow.

Please message me on LinkedIn, so I can add you to the project. Link in my bio to LinkedIn.

