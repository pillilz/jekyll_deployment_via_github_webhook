% Automatic Jekyll Website Depolyment via GitHub Webhook
% Jörg Schneider
% 2020-07-27
## Introduction

The scenario of this deployment automation is a server hosting a Jekyll based
website. The Jekyll sources are hosted on GitHub. Whenever the sources are
updated on GitHub, the server builds the website with Jekyll and depoys it on
the webserver.

## Process Overview

The Jekyll sources of the website are hosted in a GitHub repository. The
repository is configured to call a webhook on the webserver when it is updated
via push. 

The webhook is implemented as a Python script which reads a configuration file
that contains the local repository and deployment target location for one or
more repositories.

If the deployment request is valid, then a deployment command is called with
the configured parameters. The script is implemented as a bash script. It
performs the following steps:

1. Update the local repository via git pull
2. Jekyll build the local repository and move the resulting html directory to a
   uniquely named directory next to the symlink
3. Replace the symlink atomically with a link to new html directory
4. Remove old html directory

## Webserver Configuration
All configuration shown here is for Apache 2.4.

### Webhook
Configure the Python script implementing the webhook in a suitable virtual host or globally. We assume the virtual host `example.com` here.
```apache
ScriptAlias /deploy /usr/local/sbin/deploywebhookgithub
<Location /deploy>
    Require all granted
</Location>
```
Create the configuration file for the webhook in `/etc/deploywebhookgithub.json`:
```json
{
  "expected_event": "push",
  "deploy_cmd": "sudo --user=deploy_website --set-home /usr/local/sbin/deploy_website",
  "repository_ref_map": {
    "githubuser/jekyllrepo": {
      "refs/heads/master": {
        "html_symlink": "/var/www/example.com/root",
        "repository_dir": "/var/www/example.com/jekyllrepo",
        "signature_key": "random key created with: openssl rand -base64 15"
      }
    },
  }
}
```
Set permissions to allow the webserver to read the file.
```bash
chmod 640 /etc/deploywebhookgithub.json
chown root:www-data /etc/deploywebhookgithub.json
```
You can configure multiple GitHub repositories in `repository_ref_map`. The
example above includes one repository: `githubuser/jekyllrepo`

Each repository has a separate entry for the branch that is pulled. The example contains only one branch, `refs/heads/master`.

For each repository and branch the configuration contains three keys:

1. `html_symlink`: The symlink pointing to html root directory of the website. The
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

## Unix configuration
### Install Scripts
```bash
install --owner=root --group=root deploywebhookgithub deploy_website /usr/local/sbin
```
### Deployment User
The deployment script `deploy_website` is run as user `deploy_website` via sudo
from `deploywebhookgithub`. The user can be configured in
`/etc/deploywebhookgithub.json` with `deploy_cmd`.

Using a different user than the webserver user `www-data` makes the static
website read-only for the webserver.
```bash
adduser --system --ingroup www-data --disabled-password --gecos 'User for deploying websites via github webhook' deploy_website
```
Create a SSH key without passphrase for user `deploy_website`.
```bash
sudo --user=deploy_website --set-home ssh-keygen -t ed25519 -N ''
```
#### Multiple Keys
The following is only necessary if more than one key is required, e.g. because
GitHub allows deployment keys to be used only for one repository. Deployment
keys can be read-only. Another approach is to create a GitHub user for the
deployment machine and invite this user to multiple repositories.

Multiple keys can be create using different names (option `-f`). To enable
automatic selection of the appropriate key, create a
`~deploy_website/.ssh/config` with one or more aliases for github.com pointing
the the respective key.
```
Host githubalias
        HostName github.com
        IdentityFile ~/.ssh/githubalias
        IdentitiesOnly yes
```
The alias then needs to be used instead of github.com when cloning the
repository (see next section) and configured in
`/etc/deploywebhookgithub.json`.

### Sudo configuration

To allow the webserver to run the `deploy_website` script as the user with the
same name, create a file `/etc/sudoers.d/deploy_website` with the following
content.

```sudo
Cmnd_Alias DEPLOYCMD = \
        /usr/local/sbin/deploy_website /var/www/example.com/jekyllrepo /var/www/example.com/root *
%www-data       ALL=(deploy_website)NOPASSWD: DEPLOYCMD
```

The paths of the local repository and html root must match the webhook
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

> **Note:** This user has write access to the repository

### Webhook
In the GitHub repository `Settings` select `Webhooks` and `Add webhook` and enter the following parameters:

`Payload URL:` https://example.com/deploy

> **Note:** The URL needs to match the ScriptAlias in the Webserver Configuration above.

`Content type: application/json`

`Secret:` random-value

> **Note:** The secret needs ot match the value configured in `/etc/deploywebhookgithub.json`

`SSL verification: Enable SSL verifcation`

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
