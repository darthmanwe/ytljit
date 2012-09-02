module YTLJit

=begin
  Stack layout (on stack frame)


Hi     |  |Argn                   |   |
       |  |   :                   |   |
       |  |Arg2(self)             |   |
       |  |Arg1(block pointer)    |   |
       |  |Arg0(parent frame)     |  -+
       |  |Return Address         |
       +- |old bp                 | <-+
          |old bp on stack        |  -+
    EBP-> |Local Vars1            |   
          |                       |   
          |                       |   
          |Local Varsn            |   
          |Pointer to Env         |   
   SP ->  |                       |
          |                       |
LO        


  Stack layout (on heap frame)

                                      |
Hi     |  |Arg0(parent frame)     |  -+
       |  |Arg1(block pointer)    |  
       |  |Arg2(self)             |
       |  |   :                   |
       |  |Arg n                  |
       |  |Return Address         |
       +- |old bp                 |  <---+
          |Pointer to Env         |  -+  |
   SP ->  |                       |   |  |
LO        |                       |   |  |
                                      |  |
                                      |  |
       +- |                       |   |  |
       |  |free func              |   |  |
       |  |mark func              |   |  |
       |  |T_DATA                 | <-+  |                                      
       |                                 |
       |                                 |
       |  |Arg n                  |      |
       |  |   :                   |      |
       |  |Arg3(exception status) |      |
       |  |Arg2(block pointer)    |      |
       |  |Arg1(parent frame)     |      |
       |  |Arg0(self)             |      |   
       |  |Not used(reserved)     |      |
       |  |Not used(reserved)     |      |
       |  |old bp on stack        | -----+
    EBP-> |Local Vars1            |   
       |  |                       |   
       |  |                       |   
       +->|Local Varsn            |   

  enter procedure
    push EBP
    SP -> EBP
    allocate frame (stack or heap)    
    Copy arguments if allocate frame on heap
    store EBP on the top of frame
    Address of top of frame -> EBP
 
  leave procedure
    Dereference of EBP -> ESP
    pop EBP
    ret

=end

  module VM
    class CollectInfoContext
      def initialize(tnode)
        @top_node = tnode
        @modified_local_var = []
        @modified_instance_var = Hash.new
        @modified_global_var = Hash.new
        @yield_node = []

        # Options from user
        @options = {}
      end

      attr          :top_node
      attr_accessor :modified_local_var
      attr_accessor :modified_instance_var
      attr_accessor :modified_global_var
      attr_accessor :yield_node
      attr_accessor :options

      def merge_local_var(lvlist)
        res = nil
        lvlist.each do |lvs|
          if res then
            lvs.each_with_index do |lvt, i|
              dst = res[i]
              lvt.each do |idx, vall|
                dst[idx] = dst[idx] | vall
              end
            end
          else
            res = lvs.map {|lvt| lvt.dup}
          end
        end

        @modified_local_var[-1] = res
      end
    end
    
    class TypeInferenceContext
      def initialize(tnode)
        @top_node = tnode
        @current_method_signature_node = [[]]
        @current_method = [tnode]
        @convergent = false
        @visited_top_node = {}
        # Options from user
        @options = {}
      end

      def to_signature(offset = -1, cache = {})
        if offset.is_a?(Node::TopNode) then
          i = -1
          while @current_method[i] and @current_method[i] != offset
            i = i - 1
          end
          if @current_method[i] == offset then
            offset = i
          else
            # This is legal if this TopNode has only one signature 
            sigc = offset.signature_cache
            if sigc.size == 1 then
              return sigc[0]
            else
              p offset.signature_cache
              p i
              p offset.debug_info
              p @current_method.map {|e| e.debug_info}
              p @current_method.map {|e| e.class}
              raise "I can't type inference..."
            end
          end
        end

        cursignode = @current_method_signature_node[offset]
        curmethod = @current_method[offset]
        if curmethod == nil then
          return nil
        end

        cursig = curmethod.current_signature
        if cursig then
          return cursig
        end

        sigc = curmethod.signature_cache
        if sigc.size == 1 then
          return sigc[0]
        end
        
        if rsig = cache[cursignode] then
          rsig = rsig.map {|e| e.copy_type}
          return rsig
        end

        if curmethod.is_a?(Node::ClassTopNode) then
          # Can't pass block when entering a class definition
          rsig = to_signature_aux(cursignode, offset, cache)
          rsig = rsig.map {|e| e.copy_type}
          cache[cursignode] = rsig
          rsig

        elsif curmethod.is_a?(Node::TopNode) then
          prevsig = to_signature(offset - 1, cache)
          rsig = to_signature_aux2(curmethod, cursignode, 
                                   prevsig, offset, cache)
          rsig = rsig.map {|e| e.copy_type}
          cache[cursignode] = rsig
          rsig
          
        else
          raise "Maybe bug"
=begin
          prevsig = to_signature(offset - 1, cache)
          mt, slf = curmethod.get_send_method_node(prevsig)

          rsig = to_signature_aux2(mt, cursignode, prevsig, offset, cache)
          cache[cursignode] = rsig
          return rsig
=end
        end
      end

      def to_signature_aux(cursignode, offset, cache)
        sig = to_signature(offset - 1, cache)
        res = cursignode.map { |enode|
          enode.decide_type_once(sig)
        }
        
        res
      end

      def to_signature_aux2(mt, args, cursig, offset, cache)
        res = []
        args.each do |ele|
          res.push ele.decide_type_once(cursig)
        end

        if !args[1].is_a?(Node::BlockTopNode) then
          return res
        end

        ynode = mt.yield_node[0]
        if ynode and false then
          yargs = ynode.arguments
          push_signature(yargs, mt)
          ysig = to_signature_aux3(yargs, -1, cache)
          # inherit self and block from caller node
          ysig[1] = cursig[1]
          ysig[2] = cursig[2]

          args[1].type = nil
          res[1] = args[1].decide_type_once(ysig)
          #p res
          #p res[1]
          pop_signature
        else
          sig =  args[1].search_valid_signature
          if sig then
            args[1].type = nil
            res[1] = args[1].decide_type_once(sig)
          end
        end
        
        res
      end

      def to_signature_aux3(cursignode, offset, cache)
        if res = cache[cursignode] then
          return res
        end

        node = @current_method[offset]
        if node.is_a?(Node::ClassTopNode) then
          node.signature_cache[0]
        else
          cursignode2 = @current_method_signature_node[offset]
          sig = to_signature_aux3(cursignode2, offset - 1, cache)
          res = cursignode.map { |enode|
            enode.decide_type_once(sig)
          }

          cache[cursignode] = res
          res
        end
      end

      def push_signature(signode, method)
        @current_method_signature_node.push signode
        @current_method.push method
      end

      def pop_signature
        @current_method.pop
        @current_method_signature_node.pop
      end

      attr          :top_node
      attr          :current_method_signature_node
      attr          :current_method
      attr_accessor :convergent
      attr_accessor :visited_top_node
      attr_accessor :options
    end

    class CompileContext
      include AbsArch
      def initialize(tnode)
        @top_node = tnode
        @prev_context = nil
        @code_space = nil

        # Signature of current compiling method
        # It is array, because method may be nest.
        @current_method_signature = []
        
        # RETR(EAX, RAX) or RETFR(STO, XM0) or Immdiage object
        @ret_reg = RETR
        @ret_reg2 = RETR
        @ret_node = nil
#        @depth_reg = {}
        @depth_reg = Hash.new(0)
        @stack_content = []
        @reg_content = Hash.new(true)
        @reg_history = Hash.new

        # Use only type inference compile mode
        @slf = nil

        # Options from user
        @options = {}

        # Comment of type inference
        @comment = {}

        # Using XMM reg as variable
        @using_xmm_reg = []
      end

      attr          :top_node
      attr_accessor :prev_context
      attr          :code_space

      attr          :current_method_signature

      attr          :depth_reg
      attr_accessor :ret_reg
      attr_accessor :ret_reg2
      attr_accessor :ret_node

      attr          :reg_content
      attr_accessor :stack_content

      attr_accessor :slf

      attr_accessor :options
      attr_accessor :comment
      attr :using_xmm_reg
      attr_accessor :using_xmm_reg

      def set_reg_content(dst, val)
        if dst.is_a?(FunctionArgument) then
          dst = dst.dst_opecode
        end
        if dst.is_a?(OpRegistor) then
          if val.is_a?(OpRegistor) and @reg_content[val] then
            @reg_content[dst] = @reg_content[val]
          else
            @reg_content[dst] = val
          end
        elsif dst.is_a?(OpIndirect) then
          wsiz = AsmType::MACHINE_WORD.size
          if dst.reg == SPR then
            if val.is_a?(OpRegistor) and @reg_content[val] then
              cpustack_setn(-dst.disp.value / wsiz - 1, @reg_content[val])
            else
              cpustack_setn(-dst.disp.value / wsiz - 1, val)
            end
          elsif dst.reg == BPR then
            if val.is_a?(OpRegistor) and @reg_content[val] then
              # 3 means difference of SP(constructed frame) and BP
              # ref. gen_method_prologue
              cpustack_setn(-dst.disp.value / wsiz + 3, @reg_content[val])
            else
              cpustack_setn(-dst.disp.value / wsiz + 3, val)
            end
          end
        elsif dst.is_a?(OpImmidiate) then
          # do nothing and legal

        else
#          pp "foo"
#          pp dst
        end
      end

      def cpustack_push(reg)
        if @reg_content[reg] then
          @stack_content.push @reg_content[reg]
        else
          @stack_content.push reg
        end
      end

      def cpustack_pop(reg)
        cont = @stack_content.pop
        if !cont.is_a?(OpRegistor) then
          @reg_content[reg] = cont
        else
          @reg_content[reg] = @reg_content[cont]
        end
      end

      def cpustack_setn(offset, val)
        if offset >= -@stack_content.size then
          @stack_content[offset] = val
        else
          # Modify previous stack (maybe as arguments)
        end
      end

      def cpustack_pushn(num)
        wsiz = AsmType::MACHINE_WORD.size
        (num / wsiz).times do |i|
          @stack_content.push 1.2
        end
      end

      def cpustack_popn(num)
        wsiz = AsmType::MACHINE_WORD.size
        (num / wsiz).times do |i|
          @stack_content.pop
        end
      end

      def set_code_space(cs)
        oldcs = @code_space
        @top_node.add_code_space(@code_space, cs)
        @code_space = cs
        asm = @top_node.asm_tab[cs]
        if asm == nil then
          @top_node.asm_tab[cs] = Assembler.new(cs)
        end

        oldcs
      end

      def assembler
        @top_node.asm_tab[@code_space]
      end

      def reset_using_reg
        @depth_reg = Hash.new(0)
#        @depth_reg = {}
      end

      def start_using_reg_aux(reg)
        if @depth_reg[reg] then
          if @reg_content[reg] then
            assembler.with_retry do
              assembler.push(reg)
              cpustack_push(reg)
            end
          end
        else
          @depth_reg[reg] = 0
        end
        @reg_history[reg] ||= []
        @reg_history[reg].push @reg_content[reg]
        @reg_content[reg] = nil
        @depth_reg[reg] += 1
      end

      def start_using_reg(reg)
        case reg
        when OpRegistor
          if reg != TMPR and reg != XMM0 then
            start_using_reg_aux(reg)
          end

        when OpIndirect
          case reg.reg 
          when BPR

          else
            start_using_reg_aux(reg.reg)
          end

        when FunctionArgument
          regdst = reg.dst_opecode
          if regdst.is_a?(OpRegistor)
            start_using_reg_aux(regdst)
          end
        end
      end

      def end_using_reg_aux(reg)
        if @depth_reg[reg] then
          @depth_reg[reg] -= 1
          @reg_content[reg] = @reg_history[reg].pop
        else
          raise "Not saved reg #{reg}"
        end
        if @depth_reg[reg] != -1 then
          if @reg_content[reg] then
            assembler.with_retry do
              assembler.pop(reg)
              cpustack_pop(reg)
            end
          end
        else
          @depth_reg[reg] = nil
          @reg_content.delete(reg)
        end
      end

      def end_using_reg(reg)
        case reg
        when OpRegistor
          if reg != TMPR and reg != XMM0 and !XMM_REGVAR_TAB.include?(reg) then
            end_using_reg_aux(reg)
          end

        when OpIndirect
          case reg.reg 
          when BPR, TMPR

          else
            end_using_reg_aux(reg.reg)
          end

        when FunctionArgument
          regdst = reg.dst_opecode
          if regdst.is_a?(OpRegistor) then
            end_using_reg_aux(regdst)
          end
        end
      end

      def start_arg_reg(kind = FUNC_ARG)
        asm = assembler
        gen = asm.generator
        used_arg_tab = gen.funcarg_info.used_arg_tab
        if used_arg_tab.last then
#          p "#{used_arg_tab.last.keys} #{caller[0]} #{@name}"
          used_arg_tab.last.keys.each do |rno|
            start_using_reg(kind[rno])
          end
        end
      end

      def end_arg_reg(kind = FUNC_ARG)
        asm = assembler
        gen = asm.generator
        used_arg_tab = gen.funcarg_info.used_arg_tab
        if used_arg_tab.last then
          used_arg_tab.last.keys.reverse.each do |rno|
            end_using_reg(kind[rno])
          end
        end
      end

      def to_signature(offset = -1)
        @current_method_signature[offset]
      end

      def push_signature(signode, method)
        sig = signode.map { |enode|
          enode.decide_type_once(to_signature)
        }
        @current_method_signature.push sig
      end

      def pop_signature
        @current_method_signature.pop
      end
    end

    module Node
      module MethodTopCodeGen
        include AbsArch
        
        def gen_method_prologue(context)
          asm = context.assembler

          asm.with_retry do
            # Make linkage of frame pointer
            asm.push(BPR)
            asm.mov(BPR, SPR)
            asm.push(TMPR)
            asm.push(THEPR)
            asm.push(BPR)
            asm.mov(BPR, SPR)
          end

          n = context.using_xmm_reg.last
          n.times do |i|
            asm.with_retry do
              asm.push(XMM_REGVAR_TAB[i])
            end
          end

          context.set_reg_content(BPR, :old_ptr)
          context.cpustack_push(BPR)
          context.set_reg_content(TMPR, :num_of_args)
          context.cpustack_push(TMPR)
          context.set_reg_content(THEPR, :local_heap)
          context.cpustack_push(THEPR)
          context.set_reg_content(BPR, :frame_ptr)
          context.cpustack_push(BPR)
            
          context
        end
      end

      module MethodEndCodeGen
        include AbsArch

        def gen_method_epilogue(context)
          asm = context.assembler

          # Make linkage of frame pointer
          asm.with_retry do
            asm.mov(SPR, BPR)
          end

          n = context.using_xmm_reg.last
          asm.with_retry do
            asm.sub(SPR, 8 * n)
          end
          n.times do |i|
            asm.with_retry do
              asm.pop(XMM_REGVAR_TAB[n - i - 1])
            end
          end

          asm.with_retry do
            asm.pop(BPR)
            if @is_escape != :local_export and 
                @is_escape != :global_export then
              asm.pop(THEPR) 
            end
            asm.mov(SPR, BPR)
            asm.pop(BPR)
          end
          context.stack_content = []

          context
        end
      end

      module IfNodeCodeGen
        include AbsArch
      end
      
      module LocalVarNodeCodeGen
        include AbsArch

        def gen_pursue_parent_function(context, depth)
          asm = context.assembler
          save_tmpr2 = false
          if depth != 0 then
            cframe = frame_info
            creg = BPR
            asm.with_retry do
              depth.times do 
                if !cframe.parent.is_a?(BlockTopInlineNode) then
                  if !save_tmpr2 then
                    context.start_using_reg(TMPR2)
                    save_tmpr2 = true
                  end

                  asm.mov(TMPR2, cframe.offset_arg(0, creg))
                  creg = TMPR2
                end
                cframe = cframe.previous_frame
              end
            end
            context.set_reg_content(creg, cframe)
            context.ret_reg = creg
          else
            context.ret_reg = BPR
          end
          context
        end
      end
    end

    module CommonCodeGen
      include AbsArch

      def gen_alloca(context, siz)
        asm = context.assembler
        case siz
        when Integer
          add = lambda { 
            a = address_of("ytl_arena_alloca")
            $symbol_table[a] = "ytl_arena_alloca"
            a
          }
          alloca = OpVarMemAddress.new(add)
          asm.with_retry do
            asm.mov(FUNC_ARG[0], THEPR)
            asm.mov(TMPR, siz)
            asm.mov(FUNC_ARG[1], TMPR)
          end
          context = gen_save_thepr(context)
          context = gen_call(context, alloca, 2)
          asm.with_retry do
            asm.mov(THEPR, RETR)
          end
        else
          raise "Not implemented yet variable alloca"
        end
        context.ret_reg = THEPR
        context
      end

      def gen_save_thepr(context)
        casm = context.assembler
        arenaaddr = context.top_node.get_local_arena_address
        casm.with_retry do
          casm.mov(TMPR, arenaaddr)
          casm.mov(INDIRECT_TMPR, THEPR)
        end
        context
      end

      def gen_call(context, fnc, numarg, slf = nil)
        casm = context.assembler

        callpos = nil
        casm.with_retry do 
          dmy, callpos = casm.call_with_arg(fnc, numarg)
        end
        context.end_using_reg(fnc)
        vretadd = casm.output_stream.var_base_address(callpos)
        cpuinfo = []
        if slf then
          cpuinfo.push slf
        else
          cpuinfo.push self
        end
        cpuinfo.push context.reg_content.dup
        cpuinfo.push context.stack_content.dup
        cpuinfo.push context.to_signature
        context.top_node.frame_struct_array.push [vretadd, cpuinfo]
        
        if context.options[:dump_context] then
          dump_context(context)
        end
        context
      end

      def dump_context(context)
        print "---- Reg map ----\n"
        context.reg_content.each do |key, value|
          print "#{key}   #{value.class} \n"
        end

        print "---- Stack map ----\n"
#=begin
        if @frame_info then
          start = @frame_info.argument_num + 1
          ll = @frame_info.frame_layout.reverse[start..-1]
          ll.each_with_index do |vinf, i|
            ro = @frame_info.real_offset(i)
            print "    #{vinf.name}:#{vinf.size}\n"
=begin
               if mlv = @modified_local_var.last[0][ro] then
                 print "    #{mlv.class} \n"
               else
                 print "    #{vinf.class} \n"
               end
=end
          end
        end
#=end
        p "---"
        context.stack_content.each do |value|
          if value.is_a?(Symbol) then
            print "    #{value} \n"
          else
            print "    #{value.class} \n"
          end
        end
      end
    end

    module SendNodeCodeGen
      include AbsArch
      include CommonCodeGen

      def gen_make_argv(context, rarg = nil, argcomphook = nil)
        casm = context.assembler
        if rarg == nil then
          rarg = @arguments[3..-1]
        end
        cursig = context.to_signature

        # make argv
        argbyte = rarg.size * AsmType::MACHINE_WORD.size
        casm.with_retry do
          casm.sub(SPR, argbyte)
        end
        context.cpustack_pushn(argbyte)

        rarg.each_with_index do |arg, i|
          rtype = nil
          if argcomphook then
            rtype = argcomphook.call(context, arg, i)
          else
            context = arg.compile(context)
            rtype = context.ret_node.decide_type_once(cursig)
          end
          context = rtype.gen_boxing(context)
          dst = OpIndirect.new(SPR, i * AsmType::MACHINE_WORD.size)
          if context.ret_reg.is_a?(OpRegistor) or 
              context.ret_reg.is_a?(OpImmidiate32) or 
              context.ret_reg.is_a?(OpImmidiate8) then
            casm.with_retry do
              casm.mov(dst, context.ret_reg)
            end

          else
            casm.with_retry do
              casm.mov(TMPR, context.ret_reg)
              casm.mov(dst, TMPR)
            end
          end
          context.cpustack_setn(i, context.ret_node)
        end

        # Copy Stack Pointer
        # TMPR2 doesnt need save. Because already saved in outside
        # of send node
        casm.with_retry do
          casm.mov(TMPR2, SPR)
        end
        context.set_reg_content(TMPR2, SPR)

        # stack, generate call ...
        context = yield(context, rarg)

        # adjust stack
        casm.with_retry do
          casm.add(SPR, argbyte)
        end
        context.cpustack_popn(argbyte)

        context
      end
    end
  end
end
