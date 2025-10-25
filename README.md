<div align="center">

<picture>
  <source media="(prefers-color-scheme: light)" srcset="/ryu!.png" />
  <img alt="tiny corp logo" src="/ryu!.png" width="50%" height="50%" />
</picture>

yet another abandoned project
</div>

### notes (aka "cool" cuda features that aren't documented)

188 = kernel is fucked, i don't know where this error code is documented. if i remember it's something related to invalid memory access
204 = undefined behaviour. it is not "unknown error", it's "unknown behaviour". pray nvidia will fix these things
you can't do u64 mul in ptx. only mul.wide.u32 is supported. don't waste a dime of time on this anymore