# parallel

In plain terms: parallel runs several steps **at the same time**, then waits for all of them to finish before moving on. Use it when the steps don't depend on each other and you want to save time.

Run members **concurrently**, then join before continuing. All members start from the same prior state.

- **Shape:** a set of members marked `type: parallel`; the engine dispatches them together and waits for all to finish.
- **Use it for:** independent work with no ordering between members (e.g. running multiple review lenses at once — though lenses are usually expressed via [[mechanics/map]]).
- **Join:** downstream stages run only after every member completes; results are typically combined by an aggregator (see [[mechanics/aggregators]]).

Contrast with [[mechanics/sequence]] (ordered). See [[Pipeline-and-Stages]].
