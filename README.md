Instructions
============

 * install requirements: `npm i`
 * install resin-cli: `npm i resin-cli`
 * login with resin-cli: `resin login`
 * fix the 0 sized images: run `npm start`

This is quite slow as it makes a request for each image layer.
You may get temporarily banned from the `/login_` endpoint, wait and re-run the
script.
To run this on staging, prefix `resin login` and `npm start` with
`RESINRC_RESIN_URL=resinstaging.io`.

You'll need to login with a 2fa enabled account in order to fix images
belonging to 2fa enabled accounts.
