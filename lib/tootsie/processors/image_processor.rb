module Tootsie
  module Processors

    class UnsupportedImageFormat < InputError; end

    class ImageProcessor
      include PrefixedLogging

      def initialize(params = {})
        @input_url = params[:input_url]
        @versions = [params[:versions] || {}].flatten
        @extractor = Exiv2MetadataExtractor.new
      end

      def params
        return {
          :input_url => @input_url,
          :versions => @versions
        }
      end

      def execute!(&block)
        result = {:outputs => []}

        input, output = Resources.parse_uri(@input_url), nil
        temp_files = []
        begin
          input.open
          begin
            versions.each_with_index do |version_options, version_index|
              version_options = version_options.with_indifferent_access
              logger.info("Handling version: #{version_options.inspect}")

              CommandRunner.new("file :file").
                run(:file => input.file.path
              ) do |line|
                if line =~ /PDF document/
                  file = Tempfile.new(["pdf", ".png"], :encoding => 'binary')
                  temp_files << file.path
                  convert_command = "mudraw"
                  convert_command << " -o '#{file.path}'"
                  convert_command << " '#{input.file.path}'"
                  CommandRunner.new("mudraw -o '#{file.path}' -r 300 '#{input.file.path}' 1").run
                  input = Resources.parse_uri("file://#{file.path}")
                  input.open
                end
              end

              output = Resources.parse_uri(version_options[:target_url])
              output.open('w')
              begin
                result[:metadata] ||= @extractor.extract_from_file(input.file.path)

                original_depth = nil
                original_width = nil
                original_height = nil
                original_type = nil
                original_format = nil
                original_orientation = nil
                begin
                  CommandRunner.new("identify -format '%z %w %h %m %[EXIF:Orientation] %r' :file").
                    run(:file => input.file.path) do |line|
                    if line =~ /(\d+) (\d+) (\d+) ([^\s]+) (\d+)? (.+)/
                      original_depth, original_width, original_height = $~[1, 3].map(&:to_i)
                      original_format = $4.downcase
                      original_orientation = $5.try(:to_i)
                      original_type = $6
                    end
                  end
                rescue CommandExecutionFailed => e
                  if e.output =~ /^identify/
                    # This typically indicates identify itself couldn't identify, vs. some
                    # other kind of unrelated system issue
                    raise UnsupportedImageFormat
                  else
                    raise
                  end
                end
                unless original_width and original_height
                  raise "Unable to determine dimensions of input image"
                end

                if (output_format = version_options[:format])
                  # Sanitize format so we can use it in file name
                  output_format = output_format.to_s
                  output_format.gsub!(/[^\w]/, '')
                end
                output_format ||= original_format
                result[:format] = output_format

                # Correct for EXIF orientation
                dimensions_rotated = rotated_orientation?(original_orientation)
                if dimensions_rotated
                  original_width, original_height = original_height, original_width
                end

                original_aspect = original_height / original_width.to_f

                result[:width] = original_width
                result[:height] = original_height
                result[:depth] = original_depth

                medium = version_options[:medium]
                medium &&= medium.to_sym

                auto_orient = (medium == :web || version_options[:strip_metadata]) && !version_options[:ignore_exif_rotation]

                target_width, target_height =
                  version_options[:width].try(:to_i),
                  version_options[:height].try(:to_i)
                if target_width
                  target_height ||= (target_width * original_aspect).ceil
                elsif target_height
                  target_width ||= (target_height / original_aspect).ceil
                else
                  target_width, target_height = original_width, original_height
                end

                scale = (version_options[:scale] || 'down').to_sym

                scale_width, scale_height = ImageUtils.compute_dimensions(scale,
                  original_width, original_height,
                  target_width, target_height)

                output_width, output_height = nil, nil

                convert_command = "convert"
                convert_options = {
                  :input_file => input.file.path,
                  :output_file => "'#{output_format}:#{output.file.path}'"
                }

                if original_format != version_options[:format] and %(gif tiff).include?(original_format)
                  # Remove additional frames (animation, TIFF thumbnails) not
                  # supported by the output format
                  convert_command << ' -delete "1-999" -flatten -scene 1'
                end

                # Auto-orient images when web or we're stripping EXIF
                if auto_orient
                  convert_command << " -auto-orient"
                end

                if scale != :none
                  output_width, output_height = scale_width, scale_height

                  convert_command << " -resize :resize"
                  if dimensions_rotated and not auto_orient
                    # ImageMagick resizing operates on pixel dimensions, not orientation
                    convert_options[:resize] = "#{scale_height}x#{scale_width}"
                  else
                    convert_options[:resize] = "#{scale_width}x#{scale_height}"
                  end
                end
                if version_options[:crop]
                  output_width = [output_width || scale_width, target_width].min
                  output_height = [output_height || scale_height, target_height].min

                  convert_command << " -gravity center -crop :crop"
                  convert_command << " +repage"  # This fixes some animations
                  if dimensions_rotated and not auto_orient
                    # ImageMagick cropping operates on pixel dimensions, not orientation
                    convert_options[:crop] = "#{target_height}x#{target_width}+0+0"
                  else
                    convert_options[:crop] = "#{target_width}x#{target_height}+0+0"
                  end
                end
                if (trimming = version_options[:trimming])
                  if trimming.fetch(:trim, false)
                    output_width, output_height = nil, nil  # Force probing later

                    if (fuzz = trimming[:fuzz_factor])
                      convert_command << " -fuzz :fuzz"
                      convert_options[:fuzz] =
                        ([[fuzz.to_f, 1.0].min, 0.0].max * 100).round(2).to_s + '%'
                    end
                    convert_command << " -trim"
                  end
                end
                if version_options[:strip_metadata]
                  convert_command << " +profile :remove_profiles -set comment ''"
                  convert_options[:remove_profiles] = "8bim,iptc,xmp,exif"
                end

                convert_command << " -quality #{((version_options[:quality] || 1.0) * 100).ceil}%"

                if original_format =~ /^(jpeg|tiff)$/i
                  # Work around a problem with ImageMagick being too clever and "optimizing"
                  # the bit depth of RGB images that contain a single grayscale channel.
                  # Coincidentally, this avoids ImageMagick rewriting the ICC data and
                  # corrupting it in the process.
                  if original_type =~ /(?:Gray|RGB)(Matte)?$/
                    convert_command << " -type TrueColor#{$1}"
                  end
                end

                # Fix CMYK images
                if medium == :web and original_type =~ /CMYK/
                  convert_command << " -colorspace rgb"
                end

                if original_format == 'gif' and output_format == 'gif'
                  # Work around ImageMagick problem that screws up animations unless the
                  # animation frames are "coalesced" first.
                  convert_command = "convert -coalesce :input_file - | #{convert_command} - :output_file"
                else
                  convert_command << " :input_file :output_file"
                end

                CommandRunner.new(convert_command).run(convert_options)

                if version_options[:format] == 'png' and Pngcrush.available?
                  Pngcrush.process!(output.file.path)
                end

                unless output_width and output_height
                  CommandRunner.new("identify -format '%w %h %[EXIF:Orientation]' :file").
                    run(:file => output.file.path
                  ) do |line|
                    if line =~ /(\d+) (\d+) ([^\s]*)/
                      output_width, output_height = $~[1, 2].map(&:to_i)

                      # Correct for EXIF orientation
                      if $3.present? and
                        (new_orientation = $3.try(:to_i)) and
                        rotated_orientation?(new_orientation)
                        output_width, output_height = output_height, output_width
                      end
                    end
                  end
                  unless output_width and output_height
                    raise "Unable to determine dimensions of output image"
                  end
                end

                output.content_type = version_options[:content_type] if version_options[:content_type]
                output.content_type ||= case version_options[:format]
                  when 'jpeg' then 'image/jpeg'
                  when 'png' then 'image/png'
                  when 'gif' then 'image/gif'
                end
                output.save

                result[:outputs] << {
                  :url => output.public_url,
                  :width => output_width,
                  :height => output_height
                }
              ensure
                output.close
              end
            end
          end
        ensure
          input.close
          temp_files.each { |f| File.unlink(f) rescue nil }
        end
        result
      end

      attr_accessor :input_url
      attr_accessor :versions

      private

        def rotated_orientation?(orientation)
          [5, 6, 7, 8].include?(orientation)
        end

    end

  end
end
