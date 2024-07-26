Smol Snake
==========

*Side-loading Python deps into AWS lambdas*.

AWS Lambda has limits on the size of a function deployment package,
specifically, 50MB zipped and 250MB unzipped.  This makes life difficult for
Python projects with many or large dependencies, especially in the data
engineering and ML space.  This is because normally all dependencies are
bundled and zipped into the deployment package.  Common workarounds for this
involve use of [layers](https://docs.aws.amazon.com/lambda/latest/dg/chapter-layers.html)
or [container images](https://docs.aws.amazon.com/lambda/latest/dg/images-create.html).
Both increase deployment complexity considerably.

Smol Snake takes a different approach.  It works by pre-installing the
dependencies into an EFS file system and then mounting that file system
into Lambdas.

The implementation here works roughtly like this:

1. `smolsnake lock --function-source-path=<path>` generates a formal dependency
   lock file (`smolsnake` uses [`poetry`](https://github.com/python-poetry/poetry)
   and its excellent dependency solver under the hood).

2. The lock file is transmitted to a server that has write access to an EFS
   file system. The server runs `smolsnake install --lockfile=<lockfile>`
   to install all requested Python packages *individually* into the EFS mount
   using the following directory structure:

       /efs/
         <python-version-1>/
           <dep-1>/
              <ver-1.0>/
                 lib/<module>.py
              <ver-2.0>/
                 lib/<module>.py
         <python-version-2>/
           <dep-3>/
             ...

         ...

   Communication with the dependency cache server happens via SQS.

3. The lambda function source is amended to inject paths to required packages
   on the EFS mount with `smolsnake injectsyspath --lockfile=<lockfile>` into
   `sys.path` (runtime version of `PYTHONPATH`).

How to run this
---------------

1. Install the prerequisites: `terraform`, `awscli`, `python3`, `jq`.

2. Install `smolsnake` into a virtual environment with your favorite Python
   package installation method.

3. Get AWS access.

   You'll need access to an AWS account with sufficient privileges to create SQS
   queues, IAM roles and policies, lambda functions and EC2 instances (admin
   access on a dedicated account is recommended).  `smolsnake` requires no
   explicit credential configuration and expects default credentials to be
   available (either in the environment or in `~/.aws/credentials`).

4. Create the EFS cache server:

       terraform -chdir=terraform/depcache init
       terraform -chdir=terraform/depcache apply

5. Create and run demo Lambda function:

       terraform -chdir=tests/func1 init
       terraform -chdir=tests/func1 apply

6. Modify `func1/src` or make a copy to experiment with your dependency-heavy
   Python function.

Development
-----------

If you need to debug the depcache server, enable public SSH by placing
your public SSH key in
[terraform/depcache/ssh_authorized_keys](terraform/depcache/ssh_authorized_keys)
and rerunning `terraform apply`:

    terraform -chdir=terraform/depcache apply

You can then SSH to the depcache server (the IP address is in the Terraform
outputs):

    ssh -l ec2-user <decache-server-ip>

License
-------

Distributed under the Zero Clause BSD (0BSD) license.
