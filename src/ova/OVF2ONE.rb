# -----------------------------------------------------------------------------
# Copyright 2002-2013, OpenNebula Project (OpenNebula.org), C12G Labs
#
# Licensed under the Apache License, Version 2.0 (the "License"); you may
# not use this file except in compliance with the License. You may obtain
# a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# -----------------------------------------------------------------------------

require 'OVFParser4ONE'
require 'OpenNebula'
require 'rubygems/package'
require 'zlib'

#
# Transforms an OVF file into an OpenNebula template, creating all the 
# needed resources (images, virtual networks) within OpenNebula
#
class OVF2ONE
    VM_TEMPLATE = %q{
        NAME=<%= name %>
        CPU=<%= capacity[:cpu] %>
        MEMORY=<%= capacity[:memory] %>

        <% disk_array.each{|disk| %>
        <%= disk %>
        <% } %>

        <% nics_array.each{|nic| %>
        <%= nic %>
        <% } %>        

        RAW =<%= raw %>  
    }

    def initialize(ova_file)
        # Extract OVA file
        ovf_file   = unpack_ova(ova_file)

        # Parse document
        @ovfparser = OVFParser4ONE.new(ovf_file)

        # Create client to interact with OpenNebula
        begin
            @client=OpenNebula::Client.new
        rescue Exception => e
            warn "Couldn't initialize client: #{e.message}"
            exit -1
        end

        @files_prefix_path=File.dirname(xml_source)
        # TODO get this from somewhere
        @ds_id = 1
    end

    def unpack_ova(ova_file)
        contents = Gem::Package::TarReader.new(Zlib::GzipReader.open(ova_file))
        ovf_file = ""
        contents.each do |tarfile|
            destination_file = File.join ENV['PWD'], tarfile.full_name
            if tarfile.directory?
                FileUtils.mkdir_p destination_file
            else
                destination_directory = File.dirname(destination_file)
                if !File.directory?(destination_directory)
                    FileUtils.mkdir_p destination_directory 
                end
                File.open destination_file, "wb" do |f|
                    f.print tarfile.read
                end
                ovf_file = destination_file if destination_file[-3,3] == "ovf"
            end
        end
        return ovf_file
    end

    def submit
        begin
            create_needed_resources

            one_template = create_one_template
            reutrn one_template
        rescue Exception => e
            warn "Couldn't transform OVF: #{e.message}"
            exit -1
        end
    end

    def create_needed_resources
        # Register images
        @created_images = create_images
    end

    # Returns a string with the OpenNebula template for the VM
    def create_one_template
        # Get name
        name       = @ovfparser.get_name

        # Capacity
        capacity   = @ovfparser.get_capacity

        # Disks
        disk_array = @ovfparser.get_disks(@created_images)

        # NICs
        nics_array = @ovfparser.get_nics

        # RAW
        raw        = @ovfparser.get_raw

        # Create the ONE template
        begin
            one_template     = ERB.new(VM_TEMPLATE)
            one_template_str = one_template.result(binding) 
        rescue Exception => e
            warn e.message
            return error
        end
    end


    # Register images for VM disks
    # Returns a list of IDs to be 
    def create_images
        created_images = Array.new
        # First, create the images from the OVA files
        @ovfparser.get_disk_images.each do |file_name|
            created_images << create_image(file_name)
        end
        return created_images
    end

    def create_image(file_name)
        image = OpenNebula::Image.new(OpenNebula::Image.build_xml, @client)

        file_full_path = "#{@files_prefix_path}/#{file_name}"
        folder_path    = file_full_path.chomp(File.extname(file_full_path) )

        # TODO support other types as well
        prepare_vmdk_file file_name, folder_path

        template = "NAME=#{file_name}\n"
        template << "PATH=#{folder_path}"

        image.allocate(template, @ds_id)

        return {:ovfname=>file_name, :oneid=>image.id} 
    end

    def prepare_vmdk_file(file_name, folder_path)
        # Create folder for the VMDK (needed by ONE)
        Dir.mkdir(folder_path)

        # Create symlink
        File.symlink(file_full_path, "#{folder_path}/#{file_name}")
    end
end