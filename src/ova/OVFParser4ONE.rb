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

require 'rubygems'
require 'nokogiri'

#
# Parses an OVF file for OpenNebula consumption
#
class OVFParser4ONE
    # Parses the xml OVF document
    # xml_file_path -> path to the file containing the OVF metadata 
    def initialize(xml_file_path)
        @doc = Nokogiri::XML(File.read(xml_source))

        # Support for single VMs only (get the fist one)
        @virtual_hw = @doc.xpath("//ovf:VirtualHardwareSection")[0]
    end

    # Get VM name
    def get_name
        @virtual_hw.xpath("Name").text
    end

    # Get capacity (CPU & MEMORY)
    def get_capacity
        cpu_xpath = 
      "//ovf:Item[rasd:ResourceType[contains(text(),'3')]]/rasd:VirtualQuantity"

        cpu = @virtual_hw.xpath(cpu_xpath).text

        memory_xpath = 
      "//ovf:Item[rasd:ResourceType[contains(text(),'4')]]/rasd:VirtualQuantity"

        memory = @virtual_hw.xpath(memory_xpath).text

      return {:cpu => cpu, :memory => memory}
    end

    # Get files to register, returns an array with the file names
    def get_disk_images
        disk_elements = @doc.xpath("//ovf:Disk")
        file_elements = @doc.xpath("//ovf:File")
        Array.new(disk_elements.size){ |i| 
            fref = disk_elements[i].attribute("fileRef")
            @doc.xpath("//ovf:File[@id=\"#{fref}\"]")[0].attribute("href").text
        }
    end

    # Get disks to be present in the VM, returns an array with 
    # DISK string sections
    def get_disks(created_images)
        # Get the instances ids of the disks
        iids           = get_scsi_iids

        # Get all the disks described in the HW section
        disks_xpath   = "//ovf:Item[rasd:ResourceType[contains(text(),'17')]]"
        cds_xpath     = "//ovf:Item[rasd:ResourceType[contains(text(),'15')]]"

        iid_xpath     = "rasd:InstanceID"
        aop_xpath     = "rasd:AddressOnParent"
        hostr_xpath   = "rasd:HostResource"

        disk_elements = @doc.xpath(disks_xpath)

        Array.new(@virtual_hw.xpath(disks_xpath).size){|i|
            disk  = disk_elements[i]
            iid   = disk.xpath(iid_xpath).text
            aop   = disk.xpath(aop_xpath).text
            hostr = disk.xpath(hostr_xpath).text.gsub(/^ovf:\/disk\//,"")

            if iids.includes? (iid) # scsi
                target="sd" + ("a".unpack('C')[0]+aop.to_i).chr
            else # ide
                target="hd" + ("a".unpack('C')[0]+aop.to_i).chr
            end

            # Get the file ID within ONE (precreated in OVF2ONE.create_images) 
            # that corresponds with this disk
            id=get_image_id_from_disk(created_images, hostr)

            "DISK=[IMAGE_ID=\"#{id}\", TARGET=\"#{target}\"]"
        }
    end

    # Get the image ID to be used in the VM disk identified by hostr
    def get_image_id_from_disk(created_images, hostr)
        disk_element = @doc.xpath("//ovf:Disk[@diskId=\"#{hostr}\"]")
        disk_fileref = disk_element.attribute("ovf:fileRef").text

        file_element = @doc.xpath("//ovf:File[@id=\"#{disk_fileref}\"]")
        file_name    = file_element.attribute("ovf:href").text

        img=created_images.select{|image_hash| image_hash[:ovfname]==file_name}

        return img[:oneid]
    end

    # Return list of SCSI instance ids
    def get_scsi_iids
        scsi_xpath    = "//ovf:Item[rasd:ResourceType[contains(text(),'6')]]"
        iid_xpath     = "rasd:InstanceID"

        iids          = Array.new

        @virtual_hw.xpath(scsi_xpath).each{|bus|
            next if bus.xpath(name_xpath).text.downcase["scsi"]
            iids << bus.xpath(iid_xpath).text
        }

        return iids
    end

    # Return list of SCSI instance ids
    def get_nics
        nics_xpath    = "//ovf:Item[rasd:ResourceType[contains(text(),'10')]]"
        network_xpath = "rasd:Connection"
        model_xpath   = "rasd:ResourceSubType"

        nic_elements  = @doc.xpath(nics_xpath)

         Array.new(@virtual_hw.xpath(nics_xpath).size){|i|
            nic     = nic_elements[i]
            network = nic.xpath(network_xpath).text
            model   = nic.xpath(model_xpath).text

            "NIC=[NETWORK=\"#{network}\", MODEL=\"#{model}\"]"
        }
    end

    # Get all the info needed for the RAW section
    def get_raw
        "RAW=[DATA=\"#{get_buses}\"]"
    end

    # Get SCSI buses for RAW section
    def get_buses
        # Check for SCSI buses
        scsi_xpath    = "//ovf:Item[rasd:ResourceType[contains(text(),'6')]]"
        address_xpath = "rasd:Address"
        subtype_xpath = "rasd:ResourceSubType"
        name_xpath    = "rasd:ElementName"

        bus_str = ""

        @virtual_hw.xpath(scsi_xpath).each{|bus|
            next if bus.xpath(name_xpath).text.downcase["scsi"]
            address = bus.xpath(address_xpath).text
            subtype = bus.xpath(subtype_xpath).text
            bus_str << "<devices><controller type='scsi' index='#{address}'"
            bus_str << " model='#{subtype}'/></devices>"
        }

        return bus_str
    end

end