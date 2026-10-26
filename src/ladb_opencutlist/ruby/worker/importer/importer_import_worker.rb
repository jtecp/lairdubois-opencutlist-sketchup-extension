module Ladb::OpenCutList

  class ImporterImportWorker

    MATERIALS_PALETTE = %w(#4F78A7 #EF8E2C #DE545A #79B8B2 #5CA34D #ECCA48 #AE78A2 #FC9CA8 #9B755F #BAB0AC)

    EDGE_SIDES = %i(ymin ymax xmin xmax)

    def initialize(parts,

                   remove_all: false,
                   keep_definitions_settings: true,
                   keep_materials_settings: true

    )

      @parts = parts

      @remove_all = remove_all
      @keep_definitions_settings = keep_definitions_settings
      @keep_materials_settings = keep_materials_settings

    end

    # -----

    def run

      model = Sketchup.active_model
      return { :errors => [ 'tab.importer.error.no_model' ] } unless model

      response = {
          :errors => [],
      }

      definitions = model.definitions
      materials = model.materials
      active_entities = model.active_entities

      # Start a model modification operation
      model.start_operation('OCL Importing Parts', true)

      # Remove all instances, definitions and materials if needed
      if @remove_all
        active_entities.clear!
        unless @keep_definitions_settings
          definitions.purge_unused
        end
        unless @keep_materials_settings
          materials.purge_unused
        end
      end

      offset_y = 0
      imported_part_count = 0
      imported_definition_names = {}
      material_palette_index = 0

      # Add a new group of entities to keep imported objects together
      imported_group = active_entities.add_group

      @parts.each do |part|

        next unless part[:errors].empty?

        # Retrieve or Create the definition
        definition = nil
        if @remove_all && @keep_definitions_settings

          # Check if definition name already used in import
          unless imported_definition_names.has_key?(part[:name])

            # Try to retrieve definition from list
            definition = definitions[part[:name]]

          end

          # Definition exists ? -> clear it
          if definition
            definition.entities.clear!
          end

        end

        definition = definitions.add(part[:name]) unless definition   # Add new definition if it doesn't exist
        entities = definition.entities

        # Flag definition name as imported (to avoid reuse)
        imported_definition_names[definition.name] = true

        # Create the base face
        face = entities.add_face([
                                     Geom::Point3d.new(0,             0,            0),
                                     Geom::Point3d.new(part[:length], 0,            0),
                                     Geom::Point3d.new(part[:length], part[:width], 0),
                                     Geom::Point3d.new(0,             part[:width], 0)
                                 ])

        # Extrude the part
        face.pushpull(-part[:thickness])

        # Retrieve material (or create it)
        material = nil
        unless part[:material].nil?
          material_name = part[:material].strip
          material = materials[material_name]
          unless material
            material = materials.add(material_name)
            material.color = MATERIALS_PALETTE[material_palette_index]
            material_palette_index = (material_palette_index + 1) % MATERIALS_PALETTE.length
          end
        end

        # Retrieve edge materials (or create them)
        edge_materials = {}
        EDGE_SIDES.each do |side|
          next if part["edge_#{side}".to_sym].nil?
          edge_material_name = part["edge_#{side}".to_sym].strip
          edge_material = materials[edge_material_name]
          unless edge_material
            edge_material = materials.add(edge_material_name)
            edge_material.color = MATERIALS_PALETTE[material_palette_index]
            material_palette_index = (material_palette_index + 1) % MATERIALS_PALETTE.length
          end
          _setup_material_type(edge_material, MaterialAttributes::TYPE_EDGE, part["edge_#{side}_thickness".to_sym])
          edge_materials.store(side, edge_material)
        end

        unless edge_materials.empty?

          # OpenCutList detects edges only on sheet goods
          _setup_material_type(material, MaterialAttributes::TYPE_SHEET_GOOD) if material

          # Paint edge materials on side faces (length is on X axis, width on Y axis)
          entities.grep(Sketchup::Face).each do |side_face|
            center = side_face.bounds.center
            if side_face.normal.parallel?(Y_AXIS)
              side = center.y < part[:width] / 2.0 ? :ymin : :ymax
            elsif side_face.normal.parallel?(X_AXIS)
              side = center.x < part[:length] / 2.0 ? :xmin : :xmax
            else
              next
            end
            side_face.material = edge_materials[side] if edge_materials.has_key?(side)
          end

        end

        # Create definition instance(s)
        count = part[:count].nil? ? 1 : part[:count]
        for i in 0..count-1
          instance = imported_group.entities.add_instance(definition, Geom::Transformation.new(Geom::Point3d.new(0, offset_y, i * part[:thickness])))
          instance.material = material if material
          imported_part_count += 1
        end

        # Set part attributes
        definition_attributes = DefinitionAttributes.new(definition)
        definition_attributes.orientation_locked_on_axis = true           # Force part to be locked on its axis
        definition_attributes.tags = part[:tags] unless part[:tags].nil?  # Add labels if defined
        definition_attributes.write_to_attributes

        offset_y += part[:width]

      end

      # Purge extra definitions and materials if needed
      if @remove_all
        if @keep_definitions_settings
          definitions.purge_unused
        end
        if @keep_materials_settings
          materials.purge_unused
        end
      end

      # Commit operation
      if model.commit_operation

        # Cleanup data
        @parts = nil

        # Operation success -> send imported part count
        response[:imported_part_count] = imported_part_count

      else

        # Opetation failed
        response[:errors] << 'tab.importer.failed_to_import'

      end

      response
    end

    # -----

    # Set the type of a not yet configured material, with the default attributes of this type
    def _setup_material_type(material, type, thickness = nil)

      material_attributes = MaterialAttributes.new(material)
      return unless material_attributes.type == MaterialAttributes::TYPE_UNKNOWN

      defaults = PLUGIN.get_global_preset(MaterialAttributes::DEFAULTS_DICTIONARY, nil, type)

      material_attributes.type = type
      material_attributes.thickness = thickness.nil? || thickness <= 0 ? defaults['thickness'] : DimensionUtils.to_ocl_precision_s(thickness)
      material_attributes.length_increase = defaults['length_increase']
      material_attributes.width_increase = defaults['width_increase']
      material_attributes.thickness_increase = defaults['thickness_increase']
      material_attributes.std_sections = defaults['std_sections']
      material_attributes.std_lengths = defaults['std_lengths']
      material_attributes.std_widths = defaults['std_widths']
      material_attributes.std_thicknesses = defaults['std_thicknesses']
      material_attributes.std_sizes = defaults['std_sizes']
      material_attributes.grained = defaults['grained']
      material_attributes.edge_decremented = defaults['edge_decremented']
      material_attributes.raw_estimated = defaults['raw_estimated']
      material_attributes.multiplier_coefficient = defaults['multiplier_coefficient']
      material_attributes.std_volumic_masses = defaults['std_volumic_masses']
      material_attributes.std_prices = defaults['std_prices']
      material_attributes.std_cut_prices = defaults['std_cut_prices']
      material_attributes.write_to_attributes

    end

  end

end
