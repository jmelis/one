#!/usr/bin/env ruby

# -------------------------------------------------------------------------- #
# Copyright 2002-2013, OpenNebula Project (OpenNebula.org), C12G Labs        #
#                                                                            #
# Licensed under the Apache License, Version 2.0 (the "License"); you may    #
# not use this file except in compliance with the License. You may obtain    #
# a copy of the License at                                                   #
#                                                                            #
# http://www.apache.org/licenses/LICENSE-2.0                                 #
#                                                                            #
# Unless required by applicable law or agreed to in writing, software        #
# distributed under the License is distributed on an "AS IS" BASIS,          #
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.   #
# See the License for the specific language governing permissions and        #
# limitations under the License.                                             #
#--------------------------------------------------------------------------- #

require 'pp'
require 'rexml/document'

ENV['LANG']='C'

module KVM
    CONF={
        :dominfo    => 'virsh --connect LIBVIRT_URI --readonly dominfo',
        :list       => 'virsh --connect LIBVIRT_URI --readonly list',
        :dumpxml    => 'virsh --connect LIBVIRT_URI --readonly dumpxml',
        :domifstat  => 'virsh --connect LIBVIRT_URI --readonly domifstat',
        :top        => 'top -b -d2 -n 2 -p ',
        'LIBVIRT_URI' => 'qemu:///system'
    }

    def self.get_all_vm_info
        vms=get_vm_info

        info={}
        vms.each do |name, vm|
            info[name]=vm[:values]
        end

        info
    end

    def self.get_vm_names
        text=`#{virsh(:list)}`

        return [] if $?.exitstatus != 0

        lines=text.split(/\n/)[2..-1]

        lines.map do |line|
            line.split(/\s+/).delete_if {|d| d.empty? }[1]
        end
    end

    def self.process_info(uuid)
        ps=`ps auxwww | grep -- '-uuid #{uuid}' | grep -v grep`
        ps.split(/\s+/)
    end

    def self.get_vm_info(one_vm=nil)
        vms={}

        names=get_vm_names

        if names.length!=0
            names.each do |vm|
                dominfo=dom_info(vm)
                psinfo=process_info(dominfo['UUID'])

                info={}
                info[:dominfo]=dominfo
                info[:psinfo]=psinfo
                info[:name]=vm
                info[:pid]=psinfo[1]

                vms[vm]=info
            end

            cpu=get_cpu_info(vms)

            vms.each do |name, vm|
                if one_vm
                    next if name!=one_vm
                end

                c=cpu[vm[:pid]]
                vm[:cpu]=c if c

                monitor=Hash.new

                ps_data=vm[:psinfo]
                dominfo=vm[:dominfo]
                monitor[:cpu]=vm[:cpu]
                monitor[:resident_memory]=ps_data[5].to_i
                monitor[:max_memory]=dominfo['Max memory'].split(/\s+/).first.to_i

                monitor[:memory]=[monitor[:resident_memory], monitor[:max_memory]].max

                state=dominfo['State']


                monitor[:state]=get_state(state)
                monitor[:cpus]=dominfo['CPU(s)']

                values=Hash.new

                values[:state]=monitor[:state]
                values[:usedcpu]=monitor[:cpu]
                values[:usedmemory]=monitor[:memory]

                values.merge!(get_interface_statistics(name))

                vm[:values]=values
            end
        end

        if one_vm
            if vms[one_vm]
                vms[one_vm][:values]
            else
                { :state => '-' }
            end
        else
            vms
        end
    end

    def self.get_cpu_info(vms)
        pids=vms.map {|name, vm| vm[:pid] }
        pids.compact!

        cpu={}

        pids.each_slice(20) do |slice|
            data=%x{#{CONF[:top]} #{slice.join(',')}}

            lines=data.strip.split("\n")
            block_size=lines.length/2
            valid_lines=lines.last(block_size)

            first_domain = 7
            valid_lines.each_with_index{ |l,i|
                if l.match 'PID USER'
                    first_domain=i+1
                    break
                end
            }

            domain_lines=valid_lines[first_domain..-1]

            domain_lines.each do |line|
                d=line.split

                cpu[d[0]]=d[8]
            end
        end

        cpu
    end

    def self.dom_info(vmid)
        text=`#{virsh(:dominfo)} #{vmid}`

        return nil if $?.exitstatus != 0

        lines=text.split(/\n/)

        hash=Hash.new

        data=lines.map do |line|
            parts=line.split(/:\s+/)
            hash[parts[0]]=parts[1]
        end

        hash
    end

    def self.virsh(command)
        CONF[command].gsub('LIBVIRT_URI', CONF['LIBVIRT_URI'])
    end

    def self.get_interface_names(vmid)
        text=`#{virsh(:dumpxml)} #{vmid}`

        doc=REXML::Document.new(text)
        interfaces = []
        doc.elements.each('domain/devices/interface/target') do |ele|
            interfaces << ele.attributes["dev"]
        end

        interfaces
    end

    def self.get_interface_statistics(vmid)
        interfaces=get_interface_names(vmid)

        if interfaces && !interfaces.empty?
            values={}
            values[:netrx]=0
            values[:nettx]=0

            interfaces.each do |interface|
                text=`#{virsh(:domifstat)} #{vmid} #{interface}`

                text.each_line do |line|
                    columns=line.split(/\s+/)
                    case columns[1]
                    when 'rx_bytes'
                        values[:netrx]+=columns[2].to_i
                    when 'tx_bytes'
                        values[:nettx]+=columns[2].to_i
                    end
                end
            end

            values
        else
            {}
        end
    end

    def self.get_state(state)
        case state.gsub('-', '')
        when *%w{running blocked shutdown dying idle}
            'a'
        when 'paused'
            'd'
        when 'crashed'
            'e'
        else
            '-'
        end
    end
end

module XEN
    CONF={
        'XM_POLL' => 'sudo /usr/sbin/xentop -bi2'
    }

    def self.get_vm_info(vm_id)
        data = get_all_vm_info[vm_id]

        if !data
            return {:STATE => 'd'}
        else
            return data
        end
    end

    def self.get_all_vm_info
    begin
        text=`#{CONF['XM_POLL']}`
        lines=text.strip.split("\n")
        block_size=lines.length/2
        valid_lines=lines.last(block_size)

        first_domain = 4
        valid_lines.each_with_index{ |l,i|
            if l.match 'NAME  STATE'
                first_domain=i+1
                break
            end
        }

        domain_lines=valid_lines[first_domain..-1]

        domains=Hash.new

        domain_lines.each do |dom|
            dom_data=dom.gsub('no limit', 'no-limit').strip.split

            dom_hash=Hash.new

            dom_hash[:name]=dom_data[0]
            dom_hash[:state]=get_state(dom_data[1])
            dom_hash[:usedcpu]=dom_data[3]
            dom_hash[:usedmemory]=dom_data[4]
            dom_hash[:nettx]=dom_data[10].to_i * 1024
            dom_hash[:netrx]=dom_data[11].to_i * 1024

            domains[dom_hash[:name]]=dom_hash
        end

        domains
    rescue
        STDERR.puts "Error executing #{CONF['XM_POLL']}"
        nil
    end
    end

    def self.get_state(state)
        case state.gsub('-', '')[-1..-1]
        when *%w{r b s d}
            'a'
        when 'p'
            'd'
        when 'c'
            'e'
        else
            '-'
        end
    end
end


def select_hypervisor
    hypervisor=nil
    params=ARGV.clone

    params.each_with_index do |param, index|
        case param
        when '--kvm'
            hypervisor=KVM
            ARGV.delete_at(index)
        when '--xen'
            hypervisor=XEN
            ARGV.delete_at(index)
        end
    end

    if !hypervisor
        case $0
        when %r{/vmm\/kvm/}
            hypervisor=KVM
        when %r{/vmm\/xen\d?/}
            hypervisor=XEN
        end
    end

    hypervisor
end

def load_vars(hypervisor)
    case hypervisor.name
    when 'XEN'
        file='xenrc'
        vars=%w{XM_POLL}
    when 'KVM'
        file='kvmrc'
        vars=%w{LIBVIRT_URI}
    else
        return
    end

begin
    env=`. #{File.dirname($0)+"/#{file}"};env`

    lines=env.split("\n")
    vars.each do |var|
        lines.each do |line|
            if a=line.match(/^(#{var})=(.*)$/)
                hypervisor::CONF[var]=a[2]
                break
            end
        end
    end
rescue
end
end


def print_data(name, value)
    if value
        "#{name.to_s.upcase}=#{value}"
    else
        nil
    end
end



def print_one_vm_info(hypervisor, vm_id)
    info=hypervisor.get_vm_info(vm_id)

    exit(-1) if !info

    #info.merge!(get_interface_statistics(vm_id))

    values=info.map do |key, value|
        print_data(key, value)
    end

    puts values.zip.join(' ')
end

def print_all_vm_info(hypervisor)
    require 'yaml'
    require 'base64'
    require 'zlib'

    vms=hypervisor.get_all_vm_info

    compressed=Zlib::Deflate.deflate(vms.to_yaml)
    puts Base64.encode64(compressed).delete("\n")
end

def print_all_vm_template(hypervisor)
    vms=hypervisor.get_all_vm_info

    puts "VM_POLL=YES"

    vms.each do |name, data|
        number = -1

        if (name =~ /^one-\d*$/)
            number = name.split('-').last
        end

        string="VM=[\n"
        string<<"  ID=#{number},\n"
        string<<"  DEPLOY_ID=#{name},\n"

        values=data.map do |key, value|
            print_data(key, value)
        end

        monitor=values.zip.join(' ')

        string<<"  POLL=\"#{monitor}\" ]"

        puts string
    end
end

hypervisor=select_hypervisor

if !hypervisor
    STDERR.puts "Could not detect hypervisor"
    exit(-1)
end

load_vars(hypervisor)

vm_id=ARGV[0]

if vm_id=='-t'
    print_all_vm_template(hypervisor)
elsif vm_id
    print_one_vm_info(hypervisor, vm_id)
else
    print_all_vm_info(hypervisor)
end
