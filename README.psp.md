Chicken Scheme port for Sony PlayStation Portable
=================================================

Project Status
--------------

Many useful things work, but ``posixpsp.scm`` is incomplete and possibly very buggy.

Also, I haven't completed writing PSP bindings for CHICKEN yet, so you probably have to do that on your own (or wait ;) ).

Building
--------

First of all, install [PSPSDK](https://github.com/pspdev) and make sure it works properly.

After making sure several times that it works properly and compiles sample executables that work on your real PSP, follow the steps below:

1.  Compile library for PSP
    ```sh
    make clean && \
    make PREFIX=$(psp-config --psp-prefix) PLATFORM=psp \
        libchicken.a install-target install-libs install-dev install-other-files
    ```
2.  Compile cross toolchain for use on build PC
    ```sh
    make PREFIX=$(psp-config --pspdev-path) PLATFORM=linux TARGETSYSTEM=psp PROGRAM_PREFIX=psp TARGET_PREFIX=$(psp-config --psp-prefix) \
        TARGET_LIBRARIES='-lpspdebug -lpspdisplay -lpspge -lpspctrl -lpspsdk -lc -lm -lpspnet -lpspnet_inet -lpspnet_apctl -lpspnet_resolver -lpsputility -lpspuser' \
        install
    ```
3.  *(Optional)*&nbsp;&nbsp;Clone the [sample game written in CHICKEN](https://github.com/remi6397/psp_chicken_demo) to make sure your cross toolchain works
