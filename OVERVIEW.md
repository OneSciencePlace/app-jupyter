# JupyterLab

## What it is

A JupyterLab workspace that runs on a remote machine and opens in your browser.
You get the familiar notebook interface — cells, plots, a file browser, a
terminal — except the computation happens wherever the container was started,
which may be a machine far larger than the one in front of you.

Your own files are simply there. The session opens in whichever directory you
launched it from, so notebooks and data you already have are ready to use, and
anything you create is saved back to the same place.

## Use cases

- Interactive analysis on a cluster, with the compute close to large data that
  would be slow or impossible to move.
- Working from a laptop, a tablet, or a borrowed machine — anything with a
  browser will do, and nothing needs to be installed on it.
- Teaching and workshops, where every participant gets an identical environment
  and nobody spends the first hour installing software.
- Prototyping something that will eventually be submitted as a batch job.

## What's included

- JupyterLab, at a fixed version.
- A private, single-user session, reached through a link that only you have.
- A terminal inside the browser, for the moments when a notebook is the wrong
  tool.

Deliberately not included: a scientific software stack. This is the plain
starting point. Apps built on top of it add whatever their subject needs — the
object detection notebook app is one example.

## Where it can run

- **On your own computer**, through Docker.
- **On a research cluster**, through Apptainer/Singularity, as an interactive
  job on a compute node.
- **Through a science gateway**, which handles starting the session and gives
  you the link to open.

It runs unprivileged and uses a single network port, which is what allows it to
run on shared systems under normal user accounts.

## Getting started

Start the container from the directory you want to work in. It prints a private
link; open that in a browser and JupyterLab appears. When you are finished,
your files are where you left them.

Through a gateway the link is handed to you directly, and there is nothing to
run by hand.

One thing worth knowing: a notebook's saved output is not trusted when you
reopen it in a new session, so charts and interactive widgets need their cells
re-run to reappear. The repository's README explains why, and how to change it.
