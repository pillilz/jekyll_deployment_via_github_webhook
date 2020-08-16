all:
	@echo usefule targets: install adduser doc

install:
	sudo install --owner=root --group=root bin/deploywebhookgithub bin/deploy_website /usr/local/sbin

adduser:
	sudo adduser --system --ingroup www-data --disabled-password --gecos 'User for deploying websites via github webhook' deploy_website
	sudo --user=deploy_website --set-home ssh-keygen -t ed25519 -N ''

doc:	README.html

%.html: %.md
	pandoc --metadata=title:README --standalone $^ -o $@

clean:
	-rm -f README.html
	
