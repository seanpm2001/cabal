cabal-install Commands
======================

``cabal help`` groups commands into global, package, new-style project and
legacy sections. We talk in detail about some of the new-style project commands,
``help`` and ``list-bin`` but there are other commands.

::

    $ cabal help
    Command line interface to the Haskell Cabal infrastructure.

    See http://www.haskell.org/cabal/ for more information.

    Usage: cabal [GLOBAL FLAGS] [COMMAND [FLAGS]]

    Commands:
    [global]
    help              Help about commands.

    [package]
    list-bin          list path to a single executable.

    [new-style projects (forwards-compatible aliases)]
    v2-build          Compile targets within the project.
    v2-configure      Add extra project configuration
    v2-repl           Open an interactive session for the given component.
    v2-run            Run an executable.
    v2-test           Run test-suites
    v2-bench          Run benchmarks
    v2-freeze         Freeze dependencies.
    v2-haddock        Build Haddock documentation
    v2-exec           Give a command access to the store.
    v2-update         Updates list of known packages.
    v2-install        Install packages.
    v2-clean          Clean the package store and remove temporary files.
    v2-sdist          Generate a source distribution file (.tar.gz).

    [legacy command aliases]
    No legacy commands are described.

Common Arguments and Flags
--------------------------

Arguments and flags common to some or all commands are:


.. option:: --default-user-config=file

    Allows a "default" ``cabal.config`` freeze file to be passed in
    manually. This file will only be used if one does not exist in the
    project directory already. Typically, this can be set from the
    global cabal ``config`` file so as to provide a default set of
    partial constraints to be used by projects, providing a way for
    users to peg themselves to stable package collections.


.. option:: --allow-newer[=pkgs], --allow-older[=pkgs]

    Selectively relax upper or lower bounds in dependencies without
    editing the package description respectively.

    The following description focuses on upper bounds and the
    :option:`--allow-newer` flag, but applies analogously to
    :option:`--allow-older` and lower bounds. :option:`--allow-newer`
    and :option:`--allow-older` can be used at the same time.

    If you want to install a package A that depends on B >= 1.0 && <
    2.0, but you have the version 2.0 of B installed, you can compile A
    against B 2.0 by using ``cabal install --allow-newer=B A``. This
    works for the whole package index: if A also depends on C that in
    turn depends on B < 2.0, C's dependency on B will be also relaxed.

    Example:

    ::

        $ cd foo
        $ cabal configure
        Resolving dependencies...
        cabal: Could not resolve dependencies:
        [...]
        $ cabal configure --allow-newer
        Resolving dependencies...
        Configuring foo...

    Additional examples:

    ::

        # Relax upper bounds in all dependencies.
        $ cabal install --allow-newer foo

        # Relax upper bounds only in dependencies on bar, baz and quux.
        $ cabal install --allow-newer=bar,baz,quux foo

        # Relax the upper bound on bar and force bar==2.1.
        $ cabal install --allow-newer=bar --constraint="bar==2.1" foo

    It's also possible to limit the scope of :option:`--allow-newer` to single
    packages with the ``--allow-newer=scope:dep`` syntax. This means
    that the dependency on ``dep`` will be relaxed only for the package
    ``scope``.

    Example:

    ::

        # Relax upper bound in foo's dependency on base; also relax upper bound in
        # every package's dependency on lens.
        $ cabal install --allow-newer=foo:base,lens

        # Relax upper bounds in foo's dependency on base and bar's dependency
        # on time; also relax the upper bound in the dependency on lens specified by
        # any package.
        $ cabal install --allow-newer=foo:base,lens --allow-newer=bar:time

    Finally, one can enable :option:`--allow-newer` permanently by setting
    ``allow-newer: True`` in the ``~/.cabal/config`` file. Enabling
    'allow-newer' selectively is also supported in the config file
    (``allow-newer: foo, bar, baz:base``).

.. option:: --preference=preference

    Specify a soft constraint on versions of a package. The solver will
    attempt to satisfy these preferences on a "best-effort" basis.

.. option:: --enable-build-info

    Generate accurate build information for build components.

    Information contains meta information, such as component type, compiler type, and
    Cabal library version used during the build, but also fine grained information,
    such as dependencies, what modules are part of the component, etc...

    On build, a file ``build-info.json`` (in the ``json`` format) will be written to
    the root of the build directory.

    .. note::
        The format and fields of the generated build information is currently
        experimental. In the future we might add or remove fields, depending
        on the needs of other tooling.

    .. code-block:: json

        {
            "cabal-lib-version": "<cabal lib version>",
            "compiler": {
                "flavour": "<compiler name>",
                "compiler-id": "<compiler id>",
                "path": "<absolute path of the compiler>"
            },
            "components": [
                {
                "type": "<component type, e.g. lib | bench | exe | flib | test>",
                "name": "<component name>",
                "unit-id": "<unitid>",
                "compiler-args": [
                    "<compiler args necessary for compilation>"
                ],
                "modules": [
                    "<modules in this component>"
                ],
                "src-files": [
                    "<source files relative to hs-src-dirs>"
                ],
                "hs-src-dirs": [
                    "<source directories of this component>"
                ],
                "src-dir": "<root directory of this component>",
                "cabal-file": "<cabal file location>"
                }
            ]
        }

    .. jsonschema:: ./json-schemas/build-info.schema.json

.. option:: --disable-build-info

    (default) Do not generate detailed build information for built components.

    Already generated `build-info.json` files will be removed since they would be stale otherwise.


cabal list-bin
--------------

``cabal list-bin`` will either (a) display the path for a single executable or (b)
complain that the target doesn't resolve to a single binary. In the latter case,
it will name the binary products contained in the package. These products can 
be used to narrow the search and get an actual path to a particular executable.

Example showing a failure to resolve to a single executable.

::

    $ cabal list-bin cabal-install
    cabal: The list-bin command is for finding a single binary at once. The
    target 'cabal-install' refers to the package cabal-install-#.#.#.# which
    includes the executable 'cabal', the test suite 'unit-tests', the test suite
    'memory-usage-tests', the test suite 'long-tests' and the test suite
    'integration-tests2'.

For a scope that results in only one item we'll get a path.

::

    $ cabal list-bin cabal-install:exes
    /.../dist-newstyle/build/.../cabal/cabal

    $ cabal list-bin cabal-install:cabal
    /.../dist-newstyle/build/.../cabal/cabal

We can also scope to test suite targets as they produce binaries.

::

    $ cabal list-bin cabal-install:tests
    cabal: The list-bin command is for finding a single binary at once. The
    target 'cabal-install:tests' refers to the test suites in the package
    cabal-install-#.#.#.# which includes the test suite 'unit-tests', the test
    suite 'memory-usage-tests', the test suite 'long-tests' and the test suite
    'integration-tests2'.

    $ cabal list-bin cabal-install:unit-tests
    /.../dist-newstyle/.../unit-tests/unit-tests

cabal v2-configure
-------------------

``cabal v2-configure`` takes a set of arguments and writes a
``cabal.project.local`` file based on the flags passed to this command.
``cabal v2-configure FLAGS; cabal v2-build`` is roughly equivalent to
``cabal v2-build FLAGS``, except that with ``v2-configure`` the flags
are persisted to all subsequent calls to ``v2-build``.

``cabal v2-configure`` is intended to be a convenient way to write out
a ``cabal.project.local`` for simple configurations; e.g.,
``cabal v2-configure -w ghc-7.8`` would ensure that all subsequent
builds with ``cabal v2-build`` are performed with the compiler
``ghc-7.8``. For more complex configuration, we recommend writing the
``cabal.project.local`` file directly (or placing it in
``cabal.project``!)

``cabal v2-configure`` inherits options from ``Cabal``. semantics:

-  Any flag accepted by ``./Setup configure``.

-  Any flag accepted by ``cabal configure`` beyond
   ``./Setup configure``, namely ``--cabal-lib-version``,
   ``--constraint``, ``--preference`` and ``--solver.``

-  Any flag accepted by ``cabal install`` beyond ``./Setup configure``.

-  Any flag accepted by ``./Setup haddock``.

The options of all of these flags apply only to *local* packages in a
project; this behavior is different than that of ``cabal install``,
which applies flags to every package that would be built. The motivation
for this is to avoid an innocuous addition to the flags of a package
resulting in a rebuild of every package in the store (which might need
to happen if a flag actually applied to every transitive dependency). To
apply options to an external package, use a ``package`` stanza in a
``cabal.project`` file.

There are two ways of modifying the ``cabal.project.local`` file through
``cabal v2-configure``, either by appending new configurations to it, or
by simply overwriting it all. Overwriting is the default behaviour, as
such, there's a flag ``--enable-append`` to append the new configurations
instead. Since overwriting is rather destructive in nature, a backup system
is in place, which moves the old configuration to a ``cabal.project.local~``
file, this feature can also be disabled by using the ``--disable-backup``
flag.


cabal v2-update
----------------

``cabal v2-update`` updates the state of the package index. If the
project contains multiple remote package repositories it will update
the index of all of them (e.g. when using overlays).

Some examples:

::

    $ cabal v2-update                  # update all remote repos
    $ cabal v2-update head.hackage     # update only head.hackage

Target Forms
------------

A cabal command target can take any of the following forms:

-  A package target: ``package``, which specifies that all enabled
   components of a package to be built. By default, test suites and
   benchmarks are *not* enabled, unless they are explicitly requested
   (e.g., via ``--enable-tests``.)

-  A component target: ``[package:][ctype:]component``, which specifies
   a specific component (e.g., a library, executable, test suite or
   benchmark) to be built.

-  All packages: ``all``, which specifies all packages within the project.

-  Components of a particular type: ``package:ctypes``, ``all:ctypes``:
   which specifies all components of the given type. Where valid
   ``ctypes`` are:

     - ``libs``, ``libraries``,
     - ``flibs``, ``foreign-libraries``,
     - ``exes``, ``executables``,
     - ``tests``,
     - ``benches``, ``benchmarks``.

-  A module target: ``[package:][ctype:]module``, which specifies that the
   component of which the given module is a part of will be built.

-  A filepath target: ``[package:][ctype:]filepath``, which specifies that the
   component of which the given filepath is a part of will be built.

-  A script target: ``path/to/script``, which specifies the path to a script
   file. This is supported by ``build``, ``repl``, ``run``, and ``clean``.
   Script targets are not part of a package.

cabal v2-build
---------------

``cabal v2-build`` takes a set of targets and builds them. It
automatically handles building and installing any dependencies of these
targets.

In component targets, ``package:`` and ``ctype:`` (valid component types
are ``lib``, ``flib``, ``exe``, ``test`` and ``bench``) can be used to
disambiguate when multiple packages define the same component, or the
same component name is used in a package (e.g., a package ``foo``
defines both an executable and library named ``foo``). We always prefer
interpreting a target as a package name rather than as a component name.

Some example targets:

::

    $ cabal v2-build lib:foo-pkg       # build the library named foo-pkg
    $ cabal v2-build foo-pkg:foo-tests # build foo-tests in foo-pkg
    $ cabal v2-build src/Lib.s         # build the library component to
                                       # which "src/Lib.hs" belongs
    $ cabal v2-build app/Main.hs       # build the executable component of
                                       # "app/Main.hs"
    $ cabal v2-build Lib               # build the library component to
                                       # which the module "Lib" belongs
    $ cabal v2-build path/to/script    # build the script as an executable

Beyond a list of targets, ``cabal v2-build`` accepts all the flags that
``cabal v2-configure`` takes. Most of these flags are only taken into
consideration when building local packages; however, some flags may
cause extra store packages to be built (for example,
``--enable-profiling`` will automatically make sure profiling libraries
for all transitive dependencies are built and installed.)

When building a script, the executable is cached under the cabal directory.
See ``cabal v2-run`` for more information on scripts.

In addition ``cabal v2-build`` accepts these flags:

- ``--only-configure``: When given we will forego performing a full build and
  abort after running the configure phase of each target package.


cabal v2-repl
--------------

``cabal v2-repl TARGET`` loads all of the modules of the target into
GHCi as interpreted bytecode. In addition to ``cabal v2-build``'s flags,
it additionally takes the ``--repl-options`` and ``--repl-no-load`` flags.

To avoid ``ghci`` specific flags from triggering unneeded global rebuilds these
flags are now stripped from the internal configuration. As a result
``--ghc-options`` will no longer (reliably) work to pass flags to ``ghci`` (or
other repls). Instead, you should use the new ``--repl-options`` flag to
specify these options to the invoked repl. (This flag also works on ``cabal
repl`` and ``Setup repl`` on sufficiently new versions of Cabal.)

The ``repl-no-load`` flag disables the loading of target modules at startup.

Currently, it is not supported to pass multiple targets to ``v2-repl``
(``v2-repl`` will just successively open a separate GHCi session for
each target.)

It also provides a way to experiment with libraries without needing to download
them manually or to install them globally.

This command opens a REPL with the current default target loaded, and a version
of the ``vector`` package matching that specification exposed.

::

    $ cabal v2-repl --build-depends "vector >= 0.12 && < 0.13"

Both of these commands do the same thing as the above, but only exposes ``base``,
``vector``, and the ``vector`` package's transitive dependencies even if the user
is in a project context.

::

    $ cabal v2-repl --ignore-project --build-depends "vector >= 0.12 && < 0.13"
    $ cabal v2-repl --project='' --build-depends "vector >= 0.12 && < 0.13"

This command would add ``vector``, but not (for example) ``primitive``, because
it only includes the packages specified on the command line (and ``base``, which
cannot be excluded for technical reasons).

::

    $ cabal v2-repl --build-depends vector --no-transitive-deps

``v2-repl`` can open scripts by passing the path to the script as the target.

::

    $ cabal v2-repl path/to/script

The configuration information for the script is cached under the cabal directory
and can be pre-built with ``cabal v2-build path/to/script``.
See ``cabal v2-run`` for more information on scripts.

cabal v2-run
-------------

``cabal v2-run [TARGET [ARGS]]`` runs the executable specified by the
target, which can be a component, a package or can be left blank, as
long as it can uniquely identify an executable within the project.
Tests and benchmarks are also treated as executables.

See `the v2-build section <#cabal-v2-build>`__ for the target syntax.

When ``TARGET`` is one of the following:

- A component target: execute the specified executable, benchmark or test suite

- A package target:
   1. If the package has exactly one executable component, it will be selected.
   2. If the package has multiple executable components, an error is raised.
   3. If the package has exactly one test or benchmark component, it will be selected.
   4. Otherwise an issue is raised

- Empty target: Same as package target, implicitly using the package from the current
  working directory.

Except in the case of the empty target, the strings after it will be
passed to the executable as arguments.

If one of the arguments starts with ``-`` it will be interpreted as
a cabal flag, so if you need to pass flags to the executable you
have to separate them with ``--``.

::

    $ cabal v2-run target -- -a -bcd --argument

``v2-run`` also supports running script files that use a certain format. With
a script that looks like:

::

    #!/usr/bin/env cabal
    {- cabal:
    build-depends: base ^>= 4.11
                , shelly ^>= 1.8.1
    -}

    main :: IO ()
    main = do
        ...

It can either be executed like any other script, using ``cabal`` as an
interpreter, or through this command:

::

    $ cabal v2-run path/to/script
    $ cabal v2-run path/to/script -- --arg1 # args are passed like this

The executable is cached under the cabal directory, and can be pre-built with
``cabal v2-build path/to/script`` and the cache can be removed with
``cabal v2-clean path/to/script``.

A note on targets: Whenever a command takes a script target and it matches the
name of another target, the other target is preferred. To load the script
instead pass it as an explicit path: ./script

By default, scripts are run at silent verbosity (``--verbose=0``). To show the
build output for a script either use the command

::

    $ cabal v2-run --verbose=n path/to/script

or the interpreter line

::

    #!/usr/bin/env -S cabal v2-run --verbose=n

For more information see :cfg-field:`verbose`

cabal v2-freeze
----------------

``cabal v2-freeze`` writes out a **freeze file** which records all of
the versions and flags that are picked by the solver under the
current index and flags.  Default name of this file is
``cabal.project.freeze`` but in combination with a
``--project-file=my.project`` flag (see :ref:`project-file
<cmdoption-project-file>`)
the name will be ``my.project.freeze``.
A freeze file has the same syntax as ``cabal.project`` and looks
something like this:

.. highlight:: cabal

::

    constraints: HTTP ==4000.3.3,
                 HTTP +warp-tests -warn-as-error -network23 +network-uri -mtl1 -conduit10,
                 QuickCheck ==2.9.1,
                 QuickCheck +templatehaskell,
                 -- etc...


For end-user executables, it is recommended that you distribute the
``cabal.project.freeze`` file in your source repository so that all
users see a consistent set of dependencies. For libraries, this is not
recommended: users often need to build against different versions of
libraries than what you developed against.

cabal v2-bench
---------------

``cabal v2-bench [TARGETS] [OPTIONS]`` runs the specified benchmarks
(all the benchmarks in the current package by default), first ensuring
they are up to date.

cabal v2-test
--------------

``cabal v2-test [TARGETS] [OPTIONS]`` runs the specified test suites
(all the test suites in the current package by default), first ensuring
they are up to date.

cabal v2-haddock
-----------------

``cabal v2-haddock [FLAGS] [TARGET]`` builds Haddock documentation for
the specified packages within the project.

If a target is not a library :cfg-field:`haddock-benchmarks`,
:cfg-field:`haddock-executables`, :cfg-field:`haddock-internal`,
:cfg-field:`haddock-tests` will be implied as necessary.

cabal v2-exec
---------------

``cabal v2-exec [FLAGS] [--] COMMAND [--] [ARGS]`` runs the specified command
using the project's environment. That is, passing the right flags to compiler
invocations and bringing the project's executables into scope.

cabal v2-install
-----------------

``cabal v2-install [FLAGS] [TARGETS]`` builds the specified target packages and
symlinks/copies their executables in ``installdir`` (usually ``~/.cabal/bin``).

.. warning::

  If not every package has an executable to install, use ``all:exes`` rather
  than ``all`` as the target. To overwrite an installation, use
  ``--overwrite-policy=always`` as the default policy is ``never``.

For example this command will build the latest ``cabal-install`` and symlink
its ``cabal`` executable:

::

    $ cabal v2-install cabal-install

In addition, it's possible to use ``cabal v2-install`` to install components
of a local project. For example, with an up-to-date Git clone of the Cabal
repository, this command will build cabal-install HEAD and symlink the
``cabal`` executable:

::

    $ cabal v2-install exe:cabal

Where symlinking is not possible (eg. on some Windows versions) the ``copy``
method is used by default. You can specify the install method
by using ``--install-method`` flag:

::

    $ cabal v2-install exe:cabal --install-method=copy --installdir=$HOME/bin

Note that copied executables are not self-contained, since they might use
data-files from the store.

.. _adding-libraries:

Adding libraries to GHC package environments
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

It is also possible to "install" libraries using the ``--lib`` flag. For
example, this command will build the latest Cabal library and install it:

::

    $ cabal v2-install --lib Cabal

This works by managing GHC package environment files. By default, it is writing
to the global environment in ``~/.ghc/$ARCH-$OS-$GHCVER/environments/default``.
``v2-install`` provides the ``--package-env`` flag to control which of these
environments is modified.

This command will modify the environment file in the current directory:

::

    $ cabal v2-install --lib Cabal --package-env .

This command will modify the environment file in the ``~/foo`` directory:

::

    $ cabal v2-install --lib Cabal --package-env foo/

Do note that the results of the previous two commands will be overwritten by
the use of other v2-style commands, so it is not recommended to use them inside
a project directory.

This command will modify the environment in the ``local.env`` file in the
current directory:

::

    $ cabal v2-install --lib Cabal --package-env local.env

This command will modify the ``myenv`` named global environment:

::

    $ cabal v2-install --lib Cabal --package-env myenv

If you wish to create a named environment file in the current directory where
the name does not contain an extension, you must reference it as ``./myenv``.

You can learn more about how to use these environments in `this section of the
GHC manual <https://downloads.haskell.org/~ghc/latest/docs/html/users_guide/packages.html#package-environments>`_.

cabal v2-clean
---------------

``cabal v2-clean [FLAGS]`` cleans up the temporary files and build artifacts
stored in the ``dist-newstyle`` folder.

By default, it removes the entire folder, but it can also spare the configuration
and caches if the ``--save-config`` option is given, in which case it only removes
the build artefacts (``.hi``, ``.o`` along with any other temporary files generated
by the compiler, along with the build output).

``cabal v2-clean [FLAGS] path/to/script`` cleans up the temporary files and build
artifacts for the script, which are stored under the .cabal/script-builds directory.

In addition when clean is invoked it will remove all script build artifacts for
which the corresponding script no longer exists.

cabal v2-sdist
---------------

``cabal v2-sdist [FLAGS] [TARGETS]`` takes the crucial files needed to build ``TARGETS``
and puts them into an archive format ready for upload to Hackage. These archives are stable
and two archives of the same format built from the same source will hash to the same value.

``cabal v2-sdist`` takes the following flags:

- ``-l``, ``--list-only``: Rather than creating an archive, lists files that would be included.
  Output is to ``stdout`` by default. The file paths are relative to the project's root
  directory.

- ``-o``, ``--output-directory``: Sets the output dir, if a non-default one is desired. The default is
  ``dist-newstyle/sdist/``. ``--output-directory -`` will send output to ``stdout``
  unless multiple archives are being created.

- ``--null-sep``: Only used with ``--list-only``. Separates filenames with a NUL
  byte instead of newlines.

``v2-sdist`` is inherently incompatible with sdist hooks (which were removed in `Cabal-3.0`),
not due to implementation but due to fundamental core invariants
(same source code should result in the same tarball, byte for byte)
that must be satisfied for it to function correctly in the larger v2-build ecosystem.
``autogen-modules`` is able to replace uses of the hooks to add generated modules, along with
the custom publishing of Haddock documentation to Hackage.
