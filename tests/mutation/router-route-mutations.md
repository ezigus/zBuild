## File
`core/router/route.sh`

## Mutation
Swap the tier fallback order in `route_to_model` — reverse the priority so T4 (most expensive) is tried before T0 (cheapest). This causes all calls to route to the most expensive available model regardless of the requested tier.

## Expected failing test
`tests/integration/core-router-route-test.sh` — the router tests assert deterministic tier selection. With this mutation the wrong tier is selected and the model-routing event contains an unexpected tier value.

## Result
The mutation is caught: the router test fails because the emitted `model.route` event references the wrong tier.
