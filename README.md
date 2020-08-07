# Automatic Jekyll Website Deployment via GitHub Webhook

## Introduction

The scenario of this deployment automation is a server hosting a Jekyll based
website. The Jekyll sources are hosted on GitHub. Whenever the sources are
updated on GitHub, the server builds the website with Jekyll and deploys it on
the webserver.

The setup described here is used for <https://www.cryptool.org/> (as of 2020-08 still testing).

## Process Overview

The Jekyll sources of the website are hosted in a GitHub repository. The
repository is configured to call a webhook when it is updated via push. 

The webhook is implemented on the webserver as a Python script which reads a
configuration file that contains the local repository and deployment target
location for one or more repositories.

If the deployment request is valid, then a deployment script is called with the
configured parameters and the committer's email address. The script is
implemented as a bash script. It performs the following steps:

1. Update the local repository via git pull
1. Jekyll build the local repository and moves the resulting HTML directory to a
   uniquely named directory next to the symlink
1. Replace the symlink atomically with a link to new HTML directory
1. Remove old HTML directory
1. Email the Jekyll logs and errors to the committer

## Webserver Configuration

All configuration shown here is for Apache 2.4.

### Webhook

Configure the Python script implementing the webhook in a suitable virtual host
or globally by using this sample
[config](etc/apache2/conf-available/deploywebhookgithub.conf). We assume the
virtual host `example.com` here.

```apache
ScriptAlias /deploy /usr/local/sbin/deploywebhookgithub
<Location /deploy>
    Require all granted
</Location>
```

Create the configuration file for the webhook in
[`/etc/deploywebhookgithub.json`](etc/deploywebhookgithub.json):

```json
{
  "expected_event": "push",
  "deploy_cmd": "sudo --user=deploy_website --set-home /usr/local/sbin/deploy_website",
  "repository_ref_map": {
    "githubuser/jekyllrepo": {
      "refs/heads/master": {
        "html_symlink": "/var/www/example.com/root",
        "repository_dir": "/var/www/example.com/jekyllrepo",
        "signature_key": "<random key created with: openssl rand -base64 15>"
      }
    }
  }
}
```

Set permissions to allow the webserver to read the file.

```bash
sudo chmod 640 /etc/deploywebhookgithub.json
sudo chown root:www-data /etc/deploywebhookgithub.json
```
You can configure multiple GitHub repositories in `repository_ref_map`. The
example above includes one repository: `githubuser/jekyllrepo`

Each repository has a separate entry for the branch that is pulled. The example contains only one branch, `refs/heads/master`.

For each repository and branch the configuration contains three keys:

1. `html_symlink`: The symlink pointing to HTML root directory of the website. The
symlink needs to be configured in the web server as the document root and will
be replaced by `deploy_website` with a new directory containing the Jekyll
output.
1. `repository_dir`: The directory containing the local git clone of the GitHub repository.
1. `signature_key`: A random key used to authenticate GitHub to the webhook
   script. The key needs to be configured in the GitHub webhook configuration,
   as well (see below).

### Website

The virtual host of the website example.com needs to be configured with `html_symlink` (see above) as document root.

```apache
DocumentRoot "/var/www/example.com/root"
```

## Unix Configuration

### Install Scripts

```bash
sudo install --owner=root --group=root deploywebhookgithub deploy_website /usr/local/sbin
```

### Deployment User

The deployment script `deploy_website` is run as user `deploy_website` via sudo
from `deploywebhookgithub`. The user can be configured in
`/etc/deploywebhookgithub.json` with `deploy_cmd`.

Using a different user than the webserver user `www-data` makes the static
website read-only for the webserver.

```bash
sudo adduser --system --ingroup www-data --disabled-password --gecos 'User for deploying websites via github webhook' deploy_website
```

Create an SSH key without passphrase for user `deploy_website`.

```bash
sudo --user=deploy_website --set-home ssh-keygen -t ed25519 -N ''
```

#### Multiple Keys

The following is only necessary if more than one key is required, e.g. because
GitHub allows deployment keys to be used only for one repository. Deployment
keys can be read-only. Another approach is to create a GitHub user for the
deployment machine and invite this user to multiple repositories.

Multiple keys can be created using different names (option `-f`). To enable
automatic selection of the appropriate key, create a
`~deploy_website/.ssh/config` with one or more aliases for github.com pointing
to the respective key.

```
Host githubalias
        HostName github.com
        IdentityFile ~/.ssh/githubalias
        IdentitiesOnly yes
```

The alias then needs to be used instead of github.com when cloning the
repository (see next section) and configured in
`/etc/deploywebhookgithub.json`.

### Sudo Configuration

To allow the webserver to run the `deploy_website` script as the user with the
same name, create a file [`/etc/sudoers.d/deploy_website`](etc/sudoers.d/deploy_website) with the following
content.

```sudo
Cmnd_Alias DEPLOYCMD = \
        /usr/local/sbin/deploy_website /var/www/example.com/jekyllrepo /var/www/example.com/root *
%www-data       ALL=(deploy_website)NOPASSWD: DEPLOYCMD
```

The paths of the local repository and HTML root must match the webhook
configuration in `/etc/deploywebhookgithub`.  Multiple paths can be configured
as required. The wildcard at the end of the command is required for passing the
email address.

### Local Repository

The local repository needs to be cloned from the GitHub repository, such that
`git pull` gets the latest version of the branch configured in
`/etc/deploywebhookgithub.json`.

```bash
sudo --user=deploy_website --set-home git -C /var/www/example.com clone git@github.com:githubuser/jekyllrepo
```
Use the `--branch ...` option to check out different branch than the default `master`
branch.

### Jekyll

Install Jekyll as described on <https://jekyllrb.com/> so that it can be run
with `bundle exec jekyll`.


## GitHub Configuration

### Deployment Key

In the GitHub repository `Settings` select `Deploy keys` and `Add deploy key`
to add the public part of the SSH key generated previously. Keep `Allow write
access` unticked.

Another approach than using deployment keys is to add the key to a (newly
created) GitHub user and invite this user as collaborator to the repository.

> **Note:** Other than a read-only deployment key, this user/key has write
> access to the repository.

### Webhook

In the GitHub repository `Settings` select `Webhooks` and `Add webhook` and enter the following parameters:

`Payload URL:` https://example.com/deploy

> **Note:** The URL needs to match the ScriptAlias in the Webserver Configuration above.

`Content type: application/json`

`Secret:` random-value

> **Note:** The secret needs to match the value configured in `/etc/deploywebhookgithub.json`

`SSL verification: Enable SSL verifcation`

## Security

### Webserver

This section analyzes the risk for the webserver.

The webhook implementation increases the attack surface with it's REST endpoint
to a limited degree.

Calls to the REST endpoint are protected by a HMAC signature of the webhook
payload. There signature does not protection against replay attacks, which is
not particularly problematic, because apart from deploying the latest version
of the website the only negative effect is some resource usage on web server.
The replay risk can be further mitigated by protecting the endpoint with TLS,
which is advisable in any case to protect the transmitted information.  A
different signature  key can and should be used for each configured repository.

The potentially untrusted information transmitted by the webhook is used to:

1. Lookup parameters in the configuration file - **no risk**
1. Verify the signature - **no risk**
1. Determine the committer's email address - **low risk,** see below

The deployment script is called with parameters looked up from the
configuration file and the email committer's address. The former are trusted,
the latter is protected by a regex from characters with a special meaning for
the shell call to the deployment script. The residual risk of using the
externally provided email address is sending an email with the Jekyll logs to a
potentially manipulated email address.

The deployment script should be called with sudo using a non-privileged user,
as described above. This allows the website to be deployed read-only for the
webserver and protects the SSH key from the webserver.

The deployment script preforms the following actions:

1. Update the local repository via git pull - **low risk**
1. Jekyll build - **medium risk**, due to the fact that Jekyll performs complex
   processing Liquid program code. A
   [vulnerability](https://nvd.nist.gov/vuln/detail/CVE-2018-17567) in a
   previous Jekyll version has resulted in arbitrary file reads. This risk is
   somewhat mitigated by executing Jekyll with an non-privileged user and can
   be further minimized by running it in a docker container.
1. Replace the symlink atomically with a link to new HTML directory - **no risk**
1. Remove old HTML directory - **no risk**
1. Email the Jekyll logs - **low risk**, see above

In summary there the execution Jekyll poses a limited risk if further
vulnerabilities are found and the GitHub repository contains malicious input.

### Website

The integrity of the website depends on the protection of the GitHub
repository. Anybody who can push to the repository or subvert GitHub security
controls can change the website.

The SSH key used by the webserver to pull from the repository poses an
additional risk, which can be minimized by using a readonly deployment key as
described above.

In addition the integrity of the website depends on the integrity of the webserver.

## Troubleshooting

### GitHub Webhook

In the webhook configuration on GitHub all executed webhook calls are listed
and show the details including the server response. 

A 200 response code with empty body indicates that the call was accepted and
the `deploy_website` script called. A message in the body indicates that the
call was ignored.  

Response codes 40x indicate an error, e.g. a repository or branch not found in
the webhook configuration, missing information in the webhook configuration or
an invalid `signature_key`. 

A response code of 500 indicates a more fundamental error that needs to be
investigated in the webserver error logs.

### Websserver Logs

The webserver error logs show for each webhook call the JSON body, information
on errors, the `deploy_website` call with its arguments and the Jekyll output.

### Jekyll Output

The Jekyll output as well as errors detected by the `deploy_website` script are
emailed to the last git committer leading to the webhook call. For this to work
a valid email address needs to be configured by the web developer on his/her
local machine. It can be checked and updated with the following commands.

```bash
git config --global user.email
git config --global user.email name@example.com
```
