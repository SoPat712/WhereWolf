# Uncomment this line to define a global platform for your project

platform :ios, '17.0'
project 'WhereWolf.xcodeproj'

target 'WhereWolf' do
	pod 'FMDB', '2.7.12'

	post_install do |installer|
		# AFNetworking 4.0.1 includes netinet6/in6.h directly, which new SDKs
		# reject as a private-module header. netinet/in.h is the public route.
		af_reachability = File.join(installer.sandbox.root, 'AFNetworking', 'AFNetworking', 'AFNetworkReachabilityManager.m')
		if File.exist?(af_reachability)
			['AFNetworkReachabilityManager.m', 'AFHTTPSessionManager.m'].each do |name|
				path = File.join(installer.sandbox.root, 'AFNetworking', 'AFNetworking', name)
				next unless File.exist?(path)
				content = File.read(path)
				patched = content.gsub('#import <netinet6/in6.h>', '#import <netinet/in.h>')
				if content != patched
					File.chmod(0644, path)
					File.write(path, patched)
				end
			end
		end
		installer.pods_project.targets.each do |target|
			target.build_configurations.each do |config|
				config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '17.0'
			end
		end
	end
end

post_integrate do |installer|
	# The resource copier's manifest is a declared build output, so script sandboxing can stay on.
	Dir.glob(File.join(installer.sandbox.root, 'Target Support Files', 'Pods-WhereWolf', '*-resources.sh')).each do |path|
		content = File.read(path)
		content = content.gsub('RESOURCES_TO_COPY=${PODS_ROOT}/resources-to-copy-${TARGETNAME}.txt',
			'RESOURCES_TO_COPY="${DERIVED_FILE_DIR}/Pods-WhereWolf-resources-to-copy.txt"')
		content = content.gsub('rm -f "$RESOURCES_TO_COPY"', ': # Retain the declared manifest output for incremental builds.')
		content = content.gsub('rsync -avr --copy-links', 'rsync -avr --inplace --copy-links')
		File.write(path, content)
	end
	installer.aggregate_targets.map(&:user_project).uniq.each do |project|
		project.targets.select { |target| target.name == 'WhereWolf' }.each do |target|
			target.shell_script_build_phases.select { |phase| phase.name == '[CP] Copy Pods Resources' }.each do |phase|
				output = '$(DERIVED_FILE_DIR)/Pods-WhereWolf-resources-to-copy.txt'
				phase.output_paths << output unless phase.output_paths.include?(output)
				%w[Info.plist PrivacyInfo.xcprivacy].each do |name|
					file = "${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/FMDB_Privacy.bundle/#{name}"
					phase.output_paths << file unless phase.output_paths.include?(file)
				end
			end
		end
		project.save
	end
end

