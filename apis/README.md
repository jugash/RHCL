One file per API: `apis/<namespace>/<release>.yaml`, holding values for `charts/api`.

Argo CD creates an Application for each file. It creates the namespace if needed and labels it
for the mesh and the gateway. Deleting the file removes the API.
