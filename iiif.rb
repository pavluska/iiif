require 'net/https'
require 'open-uri'
require 'nokogiri'
require 'json'
require 'typhoeus'

@uuid = ARGV[0]
@kramerius = "https://kramerius.mzk.cz"
@registrkrameriu = "https://registr.digitalniknihovna.cz/libraries.json"
@url_manifest = "https://api.pavlarychtarova.cz/iiif"
# @uuid = "uuid:5ef70cb8-6398-4486-b5f7-94ba3150a052"
# @uuid = "uuid:f4561864-6a82-49c6-b530-4ca0ba9df0d4"
# @uuid = "uuid:37340ee7-621b-479d-9fd1-26ed0f2d1bdf"
# @uuid = "uuid:9743c10f-9e10-11e0-a742-0050569d679d"
# @uuid = "uuid:c82abdac-2d07-11e0-b59b-0050569d679d"
# @uuid = "uuid:6bb7a768-4afc-48bb-aa81-81abc2d69ce4"
# @uuid = "uuid:f5a09c95-2fd8-11e0-83a8-0050569d679d"

def get_xml(url)
    uri = URI(URI.encode(url))
    https = Net::HTTP.new(uri.host, uri.port)
    https.use_ssl = true
    https.open_timeout = 100
    https.read_timeout = 100
    request = Net::HTTP::Get.new(uri)
    request["Accept"] = 'application/xml'
    begin
        response = https.request(request).read_body
        return response
    rescue
        if run == 0
            return nil
        else
            get_xml(url, run - 1) 
        end
    end
end

def get_json(url)
    # t = Time.now
    uri = URI(URI.encode(url))
    https = Net::HTTP.new(uri.host, uri.port)
    https.use_ssl = true
    request = Net::HTTP::Get.new(uri)
    request.add_field "Content-Type", "application/json; charset=utf-8"
    # request.add_field "Accept-Language", "cs"
    request.add_field "Accept", "application/json"
    response = https.request(request)
    # puts (Time.now - t).to_s

    result =  JSON.parse(response.read_body)
    # puts (Time.now - t).to_s
    return result
end

def control_404(url)
    response = Net::HTTP.get_response(URI(url))
    error = response.is_a?(Net::HTTPNotFound)
    result = error
    return !result
end

def find_document_model(pid)
    uuid = "#{@uuid}".to_json
    object = get_json("#{@kramerius}/search/api/v5.0/search?fl=PID,fedora.model&q=PID:#{uuid}&rows=1500&start=0")
    response_body = object["response"]["docs"]
    model = response_body.find {|a| a['PID'] == pid}['fedora.model']
    return model.to_s
end


def mods_extractor
    errors = []
    mods = {}
    xmldoc = Nokogiri::XML get_xml("#{@kramerius}/search/api/v5.0/item/#{@uuid}/streams/BIBLIO_MODS")
        if xmldoc.nil? 
            errors << uuid
            continue
        end

    xmldoc.remove_namespaces!
    
    # sysno a sigla
    xmldoc.xpath("modsCollection/mods/recordInfo/recordIdentifier").each do |sys|
        sysno = "#{sys.text}"
        sigla = "MZK01"  #TODO
        if sysno.length == 9
            mods["sysno"] = sysno    
        end
        mods["sigla"] = sigla
    end

    # uuid
    xmldoc.xpath("modsCollection/mods/identifier").each do |id|
        if id.at("@type").to_s == "uuid"
            uuid = id.text
            if uuid.length == 36
                uuid = "uuid:#{id.text}"
            else
                uuid = "#{id.text}"
            end
            uuid2 = uuid.to_s
            mods["uuid"] = uuid2
        end

    end

    # title
    xmldoc.xpath("modsCollection/mods/titleInfo").each do |titleInfo|
        title = titleInfo.at("title").text
        if !titleInfo.at("nonSort").nil?
            nonsort = titleInfo.at("nonSort").text
            mods["title"] = "#{nonsort}#{title}"
        else
            mods["title"] = title
        end
    end

    # authors
    if xmldoc.at("modsCollection/mods/name")
        authors = []
        xmldoc.xpath("modsCollection/mods/name").each do |name|
            author = ""
            if name.at("//namePart/@type").to_s == "family"
                family = ""
                given = ""
                termOfAddress = ""
                date = ""
                name.xpath("namePart").each do |namePart|
                    if namePart.at("@type").to_s == "family"
                        family = namePart.text
                    end
                    if namePart.at("@type").to_s == "given"
                        given = ", #{namePart.text}"
                    end
                    if namePart.at("@type").to_s == "termsOfAddress"
                        termOfAddress = ", #{namePart.text}"
                    end
                    if namePart.at("@type").to_s == "date"
                        date = ", #{namePart.text}"
                    end
                end
                author = "#{family}#{given}#{termOfAddress}#{date}"
            end          
            if name.at("//namePart[not(@type)]")
                name2 = ""
                termOfAddress = ""
                date = ""
                name.xpath("namePart").each do |namePart|
                    if namePart.at("@type").to_s == "termsOfAddress"
                        termOfAddress = ", #{namePart.text}"
                    elsif namePart.at("@type").to_s == "date"
                        date = ", #{namePart.text}"
                    # elsif namePart.at("[not(@type)]")
                    else
                        name2 = namePart.text
                    end   
                end
                author = "#{name2}#{termOfAddress}#{date}"
            end

            authors.push(author)
            mods["authors"] = authors
        end
    end

    # nakladatelske udaje
    published = ""
    xmldoc.xpath("modsCollection/mods/originInfo").each do |originInfo|
        
        # place
        originInfo.xpath("place").each do |place|
            if place.xpath("placeTerm/@type").to_s == "text"
                places = place.at("placeTerm").text
                published = "#{published}#{places}"
            end
        end
        
        # publisher
        if !originInfo.xpath("publisher").nil?
            originInfo.xpath("publisher").each do |pub|
                publisher = pub.text
                published = "#{published}: #{publisher}"
            end
        end

        # date
        if !originInfo.xpath("dateIssued").nil?
            dates = {}
            originInfo.xpath("dateIssued").each do |dat|
                if dat.at("@point").to_s == "start"
                    dates["date_start"] = dat.text
                elsif dat.at("@point").to_s == "end"
                    dates["date_end"] = dat.text
                else
                    dates["date"] = dat.text
                end
            end
            if published.length > 0
                published = "#{published}, #{dates["date"]}"
            else
                published = "#{dates["date"]}"
            end
        end
        mods["published"] = published
    end
    return mods
end

def create_label
    mods = mods_extractor
    label = {"cz" => [mods["title"]]}
    return label
end

def create_metadata
    mods = mods_extractor
    metadata = []
    if !mods["title"].nil?
        title = {"label" => {"cz" => ["Název"]}, "value" => {"none" => [mods["title"]]}}
        metadata.push(title)
    end
    if !mods["authors"].nil?
        author = {"label" => {"cz" => ["Autor"]}, "value" => {"none" => [mods["authors"]]}}
        metadata.push(author)
    end
    if !mods["published"].nil?
        published = {"label" => {"cz" => ["Nakladatelské údaje"]}, "value" => {"none" => [mods["published"]]}}
        metadata.push(published)
    end
    # return JSON.pretty_generate(metadata)
    return metadata
end

def create_provider(sigla)
    object = get_json("https://registr.digitalniknihovna.cz/libraries.json")
    id = object.find {|h1| h1['sigla'] == sigla}["library_url"]
    # id = object[0]["library_url"]
    label_cz = object.find {|h1| h1['sigla'] == sigla}["name"]
    label_en = object.find {|h1| h1['sigla'] == sigla}["name_en"]
    homepage = object.find {|h1| h1['sigla'] == sigla}["url"]
    logo = object.find {|h1| h1['sigla'] == sigla}["logo"]
    provider = [{"id" => id, "type" => "Agent", "label" => {"cz" => [label_cz]}, "homepage" => [{ "id" => homepage, "type" => "Text", "label" => {"cz" => [label_cz]}, "format" => "text/html"}], "logo" => [{"id" => logo, "type" => "Image", "format" => "image/png"}]}]
    return provider
end

def create_homepage
    mods = mods_extractor
    uuid = mods["uuid"]
    sysno = mods["sysno"]
    sigla = mods["sigla"]
    homepage = []
    # http://www.digitalniknihovna.cz/mzk/uuid/uuid:f4561864-6a82-49c6-b530-4ca0ba9df0d4
    if !uuid.nil?
        dk = {"id" => "http://www.digitalniknihovna.cz/mzk/uuid/#{uuid}", "type" => "Text", "label" => { "cz" => ["Odkaz do Digitální knihovny"]}}
        homepage.push(dk)
    end
    if !sysno.nil?
        vufind = {"id" => "https://vufind.mzk.cz/Record/#{sigla}-#{sysno}", "type" => "Text", "label" => { "cz" => ["Odkaz do Vufindu"]}}
        homepage.push(vufind)
    end
        # vufind = "https://vufind.mzk.cz/Record/MZK01-#{sysno}"
    # homepage = [{"id" => dk, "type" => "Text", "label" => { "cz" => ["Odkaz do Digitální knihovny"]}}, {"id" => vufind, "type" => "Text", "label" => { "cz" => ["Odkaz do Vufindu"]}}]
    return homepage
end

def create_behavior
    behavior = ["paged"]
    return behavior
end

def create_list_of_pages
    uuid = "#{@uuid}".to_json

    # nactu a seradim si stranky    
    object = get_json("#{@kramerius}/search/api/v5.0/search?fl=PID,details,rels_ext_index&q=parent_pid:#{uuid} AND fedora.model:page&rows=1500&start=0")
    response_body = object["response"]["docs"]
    sorted_object = response_body.sort { |a, b| a["rels_ext_index"] <=> b["rels_ext_index"]}
    # puts JSON.pretty_generate(sorted_object)

    pids = []
    pages = []
    
    # pro kazdou stranku:
    sorted_object.each do |page|
        # puts "sorted object - start" + Time.now.to_s
        page_properties = {}
        index = page["rels_ext_index"][0]
        uuid_page = page["PID"]
        pids.push(uuid_page)
        page_properties["index"] = index
        page_properties["pid"] = uuid_page

        # id pro vsechny urovne
        page_properties["canvas_id"] = "#{@url_manifest}/#{@uuid}/canvases/#{index}"
        page_properties["annotationPage_id"] = "#{@url_manifest}/#{@uuid}/canvases/#{index}/ap"
        page_properties["annotation_id"] = "#{@url_manifest}/#{@uuid}/canvases/#{index}/ap/a"
        page_properties["body_id"] = "#{@kramerius}/search/iiif/#{uuid_page}/full/full/0/default.jpg"
        page_properties["alto_id"] = "#{@kramerius}/search/api/v5.0/item/#{uuid_page}/streams/ALTO"
        page_properties["thumb_id"] = "#{@kramerius}/search/img?pid=#{uuid_page}&stream=IMG_THUMB&action=GETRAW"

        # cislo strany
        canvas_label = ""
        if !page["details"][0].split("##")[0].nil?
            page_properties["page_number"] = page["details"][0].split("##")[0].strip.sub(" ", "")
        end
        
        # typ strany
        page_type = ""
        if !page["details"][0].split("##")[1].nil?
            page_properties["page_type"] = page["details"][0].split("##")[1].strip.sub(" ", "")
        end
        pages.push(page_properties)
        # puts "sorted object -  end" + Time.now.to_s
    end

    # typhoeus test
    hydra = Typhoeus::Hydra.new
    requests = pids.map{ |pid|
        # puts "hydra" + Time.now.to_s
        request = Typhoeus::Request.new( 
        "#{@kramerius}/search/iiif/#{pid}/info.json",
        method: :get,
        headers: {
            "Content-Type" => "application/json"
        },
        followlocation: true
        )
        hydra.queue(request)
        request
    }
    hydra.run
    responses = requests.map { |request|
        # puts "hydra - end " + Time.now.to_s
        JSON(request.response.body) if request.response.code === 200
    }

    pages.each do |page|
        # puts "kombinace" + Time.now.to_s
        pid2 = "#{@kramerius}/search/iiif/#{page["pid"]}"
        responses.each do |item|
            if !item["@id"].nil?
                if pid2 === item["@id"]
                    width = item["width"]
                    height = item["height"]
                    thumb_width = item["sizes"][0]["width"]
                    thumb_height = item["sizes"][0]["height"]
                    page["width"] = width
                    page["height"] = height
                    page["thumb_width"] = thumb_width
                    page["thumb_height"] = thumb_height
                end
            end
        end
    end
    return pages
end
    #     # nacist velikost obrazku z IIIF info.json
    #     # puts Time.now.to_s
    #     # puts "https://kramerius.mzk.cz/search/iiif/#{uuid_page}/info.json"
    #     # image_object = get_json("https://kramerius.mzk.cz/search/iiif/#{uuid_page}/info.json")
    #     # next
    #     # width = image_object["width"]
    #     # height = image_object["height"]

    #     # nacist velikost obrazku ze ZOOMIFY
    #     image_object = Nokogiri::XML get_xml("https://kramerius.mzk.cz/search/zoomify/#{uuid_page}/ImageProperties.xml")
    #     width = image_object.xpath("IMAGE_PROPERTIES/@WIDTH")
    #     height = image_object.xpath("IMAGE_PROPERTIES/@HEIGHT")

def create_items
    itemsCanvas = []
    pages = create_list_of_pages
    alto = control_404("#{@kramerius}/search/api/v5.0/item/#{pages[0]['pid']}/streams/ALTO")

    pages.each do |page|
        itemsAnnotationPage = []
        itemsAnnotation = []
        seeAlso = {"id" => page["alto_id"], 
                "type" => "Alto", 
                "profile" => "http://www.loc.gov/standards/alto/v3/alto.xsd", 
                "label" => { "none" => ["ALTO XML"] }, 
                "format" => "text/xml"}
        body_service = {}
        thumb_service = {}
        canvas_thumbnail = {"id" => page["thumb_id"], 
                            "type" => "Image", 
                            "width" => page["thumb_width"], 
                            "height" => page["thumb_height"], 
                            "service" => [thumb_service]}
        body = {"id" => page["body_id"], 
                "type" => "Image", 
                "width" => page["width"], 
                "height" => page["height"], 
                "format" => "image/jpeg", 
                "service" => [body_service]}
        annotation = {"id" => page["annotation_id"], 
                      "type" => "Annotation", 
                      "motivation" => "painting", 
                      "body" => body, 
                      "target" => page["canvas_id"]}
        annotationPage = {"id" => page["annotationPage_id"], 
                          "type" => "AnnotationPage", 
                          "items" => itemsAnnotation}
        if alto
            canvas = {"id" => page["canvas_id"], 
                      "type" => "Canvas", 
                      "label" => { "none" => [page["page_number"]]}, 
                      "width" => page["width"], 
                      "height" => page["height"], 
                      "thumbnail" => [canvas_thumbnail], 
                      "seeAlso" => [seeAlso], 
                      "items" => itemsAnnotationPage }
        else
            canvas = {"id" => page["canvas_id"], 
                "type" => "Canvas", 
                "label" => { "none" => [page["page_number"]]}, 
                "width" => page["width"], 
                "height" => page["height"], 
                "thumbnail" => [canvas_thumbnail],  
                "items" => itemsAnnotationPage }
        end
        itemsAnnotation.push(annotation)
        itemsAnnotationPage.push(annotationPage)
        itemsCanvas.push(canvas)
    end
    return itemsCanvas
end

def create_iiif_monograph
    # puts "------" + Time.now.to_s
    iiif = Hash.new(0)
    context = "http://iiif.io/api/presentation/3/context.json"
    id = "#{@url_manifest}/#{@uuid}/manifest.json"
    type = "Manifest"
    provider = create_provider("BOA001")
    homepage = create_homepage
    iiif = {"@context" => context, 
                "id" => id, 
                "type" => type, 
                "label" => create_label, 
                "metadata" => create_metadata, 
                "behavior" => create_behavior, 
                "provider" => provider, 
                "homepage" => homepage, 
                "items" => create_items
            }
    # puts "------" + Time.now.to_s
    return JSON.pretty_generate(iiif)
end

def create_iiif_periodical
    iiif = Hash.new(0)
    context = "http://iiif.io/api/presentation/3/context.json"
    id = "#{@url_manifest}/#{@uuid}/collection.json"
    type = "Collection"
    provider = create_provider("BOA001")
    homepage = create_homepage
    iiif = {"@context" => context, 
                "id" => id, 
                "type" => type, 
                "label" => create_label, 
                "metadata" => create_metadata, 
                "provider" => provider, 
                "homepage" => homepage, 
                "items" => create_items
            }
    return JSON.pretty_generate(iiif)
end

def create_iiif
    if find_document_model(@uuid).to_s == "monograph" || "map" || "graphic"
        puts create_iiif_monograph
    elsif find_document_model(@uuid).to_s == "periodical"
        puts create_iiif_periodical
    else puts find_document_model(@uuid).to_s
    end
end


puts create_iiif
