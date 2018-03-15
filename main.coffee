Promise = require('bluebird')
_ = require('lodash')
Progress = require('progress')
request = require('request-promise')
resin = require('resin-sdk')
settings = require('resin-settings-client')

CONCURRENT_REQUESTS_TO_REGISTRY = 10

resin.setSharedOptions(
	apiUrl: settings.get('apiUrl')
	imageMakerUrl: settings.get('imageMakerUrl')
	dataDirectory: settings.get('dataDirectory')
	retries: 2
)

sdk = resin.fromSharedOptions()

getZeroSizedImages = ->
	images = await sdk.pine.get
		resource: 'image'
		options:
			filter:
				image_size: 0
				image__is_part_of__release:
					$any:
						$alias: 'iipor'
						$expr:
							iipor:
								is_part_of__release:
									$any:
										$alias: 'ipor'
										$expr:
											ipor:
												status: 'success'
			expand:
				image__is_part_of__release:
					$select: [ 'id' ]
					$expand:
						is_part_of__release:
							$select: [ 'id', 'status' ]
							$expand:
								is_created_by__user:
									$select: [ 'username' ]
			select: [
				'id'
				'image_size'
				'is_stored_at__image_location'
			]
	images.map (image) ->
		repo = image.is_stored_at__image_location
		repo = repo.slice(repo.search('/') + 1).toLowerCase()
		{
			id: image.id
			user: image.image__is_part_of__release[0].is_part_of__release[0].is_created_by__user[0].username
			repo
		}

api = (endpoint, params, method = 'GET') ->
	data =
		baseUrl: sdk.pine.API_URL
		method: method
		url: endpoint
	data[if method == 'GET' then 'qs' else 'body'] = params
	(await sdk.request.send(data)).body

getRegistryToken = (registryHost, imageRepo) ->
	params =
		service: registryHost,
		scope: "repository:#{imageRepo}:pull"
	(await api('auth/v1/token', params)).token

registry = (registryHost, endpoint, registryToken, headers, decodeJson, followRedirect, encoding) ->
	request({
		uri: "https://#{registryHost}/#{endpoint}"
		headers: _.merge({}, headers, Authorization: "Bearer #{registryToken}")
		json: decodeJson
		simple: false
		resolveWithFullResponse: true
		followRedirect
		encoding
	})

getLayerSize = (registryHost, token, imageRepo, blobSum) ->
	# the last 4 bytes of each gzipped layer are the layer size % 32
	headers = { Range: 'bytes=-4' }
	# request(...) will re-use the same headers if it gets redirected.
	# We don't want to send the registry token to s3 so we ask it to not follow
	# redirects and issue the second request manually.
	response = await registry(registryHost, "v2/#{imageRepo}/blobs/#{blobSum}", token, headers, false, false, null)
	if response.statusCode == 206
		# no redirect, like in the devenv
	else if response.statusCode == 307
		# redirect, like on production or staging
		response = await request({ uri: response.headers.location, headers, resolveWithFullResponse: true, encoding: null })
	else
		throw new Error('Unexpected status code from the registry: ' + response.statusCode)
	response.body.readUIntLE(0, 4)

getImageSize = (imageRepo, registry2Url, bar) ->
	registryToken = await getRegistryToken(registry2Url, imageRepo)
	response = await registry(registry2Url, "v2/#{imageRepo}/manifests/latest", registryToken, {}, true, true)
	layersCount = _.countBy(_.map(response.body.fsLayers, 'blobSum'))
	sizes = await Promise.map(
		_.entries(layersCount)
		(layer) ->
			layerSize = await getLayerSize(registry2Url, registryToken, imageRepo, layer[0])
			layerSize * layer[1]
		concurrency: CONCURRENT_REQUESTS_TO_REGISTRY
	)
	result = _.sum(sizes)
	if result == 0
		bar.interrupt("0 size for #{imageRepo}, this is unexpected. The registry response was #{response.statusCode} #{JSON.stringify(response.body, null, 4)}")
	result

updateSize = (imageId, size) ->
	await sdk.pine.patch
		resource: 'image'
		id: imageId
		body:
			image_size: size
	return

loginAsDisposer = (username) ->
	# get the current user token
	token = await sdk.auth.getToken()
	# ask for a temporary other user token (30s)
	#userTmpToken = (await sdk.request.send(baseUrl: sdk.pine.API_URL, url: '/login_', method:'PATCH', body: { username })).body
	userTmpToken = (await api('/login_', { username }, 'PATCH'))
	# set it as our current token
	await sdk.auth.loginWithToken(userTmpToken)
	# exchange the short lived token for a normal one
	userToken = (await sdk.request.send(baseUrl: sdk.pine.API_URL, url: '/user/v1/refresh-token')).body
	# set it as our current token
	await sdk.auth.loginWithToken(userToken)
	Promise.resolve().disposer ->
		# restore the original token
		sdk.auth.loginWithToken(token)


main = ->
	images = await getZeroSizedImages()
	imagesByUser = _.groupBy(images, 'user')
	registry2Url = (await sdk.settings.getAll()).registry2Url
	console.log('images to update:', JSON.stringify(imagesByUser, null, 4))
	bar = new Progress('[:bar] :current/:total; :rate images/s; :percent; :etas left; current user: :user; image: :image', total: images.length, width: 30)
	for user in _.keys(imagesByUser).sort()
		await Promise.using loginAsDisposer(user), ->
			for image in imagesByUser[user]
				size = await getImageSize(image.repo, registry2Url, bar)
				if size != 0
					try
						await updateSize(image.id, size)
						bar.interrupt("#{user} #{image.id} #{image.repo} #{size}")
					catch e
						bar.interrupt("couldn't update size #{size} for image #{JSON.stringify(image)}: #{e}")
				bar.tick({ user, image: image.repo })
	return

wrapper = ->
	try
		await main()
	catch error
		console.error(error)
		process.exitCode = 1

wrapper()
